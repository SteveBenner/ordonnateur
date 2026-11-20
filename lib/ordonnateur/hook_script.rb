#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "digest"
require "securerandom"
require "shellwords"
require "time"

require_relative "model"
require_relative "inventory"

module Ordonnateur
  module HookScript
    Result = Struct.new(
      :path, :resolved_from, :kind, :size, :mtime, :sha256, :line_count, :shebang, :executable, :content, :refusal,
      keyword_init: true
    )

    SERVE_LIMIT = 1024 * 1024
    CONTENT_LIMIT = 256 * 1024
    INTERPRETERS = %w[ruby python python3 node bash sh zsh env].freeze
    CREDENTIAL_DIRS = %w[.ssh .gnupg .aws .config/gcloud .config/rstack/secrets .rstack/secrets].freeze
    WRITABLE_SCOPES = {
      "claude-code" => %w[user local], "hermes" => %w[user], "antigravity" => %w[global workspace]
    }.freeze
    ROOT = File.expand_path("../..", __dir__)

    module_function

    def command_words(hook)
      words = Shellwords.split(hook.command.to_s)
      words.concat(hook.args.map(&:to_s)) if hook.args
      words
    rescue ArgumentError
      []
    end

    def inline_flag?(word, interpreter)
      return false if interpreter == "env" || word.start_with?("--")

      word == "-c" || (word.start_with?("-") && word.length <= 3 && word.include?("c"))
    end

    def candidate(words)
      index = 0
      while index < words.length && INTERPRETERS.include?(File.basename(words[index]))
        interpreter = File.basename(words[index])
        index += 1
        while index < words.length
          word = words[index]
          return nil if inline_flag?(word, interpreter)

          break unless word.start_with?("-") || (interpreter == "env" && word.include?("="))

          index += 1
        end
      end
      return nil if index >= words.length

      [words[index], index.zero? ? "command" : "args"]
    end

    def expand(word, project_root:, home:, plugin_root:)
      text = word.sub(/\A~(?=\/|\z)/, home)
      {
        "HOME" => home, "CLAUDE_PROJECT_DIR" => project_root.to_s, "CLAUDE_PLUGIN_ROOT" => plugin_root.to_s
      }.each do |name, value|
        text = text.gsub("${#{name}}", value).gsub(/\$#{name}(?![A-Za-z0-9_])/, value)
      end
      text
    end

    def locate(word, project_root)
      return File.expand_path(word, project_root || Dir.pwd) if word.include?("/")

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir.empty? ? "." : dir, word)
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end

    def credential?(path, home)
      CREDENTIAL_DIRS.any? do |dir|
        base = File.join(home, dir)
        path == base || path.start_with?("#{base}/")
      end || File.basename(path).start_with?(".env")
    end

    def empty_result(path, kind, refusal, from)
      Result.new(
        path: path, resolved_from: from, kind: kind, size: nil, mtime: nil, sha256: nil, line_count: nil, shebang: nil,
        executable: false, content: nil, refusal: refusal
      )
    end

    def resolve(hook, project_root: nil, home: Dir.home)
      found = candidate(command_words(hook))
      return empty_result(nil, "missing", "the command names no script file", nil) unless found

      word, from = found
      expanded = expand(word, project_root: project_root, home: home, plugin_root: hook.plugin_root)
      located = locate(expanded, project_root)
      return empty_result(expanded, "missing", "#{expanded} does not exist", from) unless located
      return empty_result(located, "missing", "#{located} does not exist", from) unless File.exist?(located)

      real = File.realpath(located)
      if credential?(real, home) || credential?(located, home)
        return empty_result(real, "refused", "the file is under a credential directory and is never served", from)
      end
      return empty_result(real, "refused", "#{real} is not a regular file", from) unless File.file?(real)

      read_file(real, from)
    rescue SystemCallError => e
      empty_result(located || expanded, "unreadable", "#{located || expanded} is unreadable: #{e.message}", from)
    end

    def read_file(path, from)
      stat = File.stat(path)
      base = {
        path: path, resolved_from: from, size: stat.size, mtime: stat.mtime.utc.iso8601,
        executable: File.executable?(path), refusal: nil
      }
      if stat.size > SERVE_LIMIT
        return Result.new(**base, kind: "too_large", sha256: nil, line_count: nil, shebang: nil, content: nil,
                                  refusal: "#{path} is above #{SERVE_LIMIT} bytes")
      end
      bytes = File.binread(path)
      sha = Digest::SHA256.hexdigest(bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      if bytes.include?("\0") || !text.valid_encoding?
        return Result.new(**base, kind: "binary", sha256: sha, line_count: nil, shebang: nil, content: nil,
                                  refusal: "#{path} is not UTF-8 text")
      end
      first = text.lines.first.to_s
      shebang = first.start_with?("#!") ? first.chomp : nil
      if stat.size > CONTENT_LIMIT
        return Result.new(**base, kind: "too_large", sha256: sha, line_count: text.lines.length, shebang: shebang,
                                  content: nil, refusal: "#{path} is above #{CONTENT_LIMIT} bytes")
      end
      Result.new(**base, kind: "text", sha256: sha, line_count: text.lines.length, shebang: shebang, content: text)
    rescue SystemCallError, IOError => e
      empty_result(path, "unreadable", "#{path} is unreadable: #{e.message}", from)
    end

    def pinned?(hook)
      case hook.harness
      when "hermes" then Harnesses::Hermes.pinned?(hook)
      when "antigravity" then Harnesses::Antigravity.pinned?(hook)
      when "claude-code" then Inventory.hard_guard?(hook)
      else false
      end
    end

    def pinned_text(hook)
      reason = hook.policy_reason
      reason ? "is pinned: #{reason}" : "is pinned: a guard that must not be changed"
    end

    def hook_refusal(hook)
      return "is a Codex hook; Codex files are read-only" if hook.harness == "codex"
      return "is a plugin hook; plugin files are never edited" if hook.plugin
      return "is an ordonnateur dispatcher" if hook.dispatcher?
      return pinned_text(hook) if pinned?(hook)

      scopes = WRITABLE_SCOPES[hook.harness]
      return "is in the #{hook.scope} scope, which ordonnateur cannot write" unless scopes && scopes.include?(hook.scope)
      if hook.harness == "antigravity" && %w[file-skipped disabled-plugin].include?(hook.status)
        return "is in a file Antigravity skips or in a disabled plugin"
      end

      nil
    end

    def verdict(refusal)
      { allowed: refusal.nil?, refusal: refusal }
    end

    def delete_fields(harness, scope, hook)
      {
        classification: "delete", needs_confirm: false, hold_required: true,
        deleted: { "hook_id" => hook.id, "event" => hook.event, "harness" => harness, "scope" => scope, "hook" => hook }
      }
    end

    def deletability(hook, hooks:, project_root: nil)
      verdict(hook_refusal(hook))
    end

    def script_refusal(hook, hooks, project_root)
      script = resolve(hook, project_root: project_root)
      unless script.kind == "text"
        return "the script is #{script.kind}: #{script.refusal}"
      end
      return "#{script.path} is reached through a symbolic link" if linked?(hook, project_root)

      stat = File.stat(script.path)
      return "#{script.path} is not owned by the user" unless stat.uid == Process.euid
      return "#{script.path} is not writable" unless File.writable?(script.path)

      shared = Array(hooks).any? do |other|
        next false if other.equal?(hook) || other.id == hook.id || !pinned?(other)

        found = resolve(other, project_root: project_root)
        found.path && found.path == script.path
      end
      shared ? "#{script.path} is also run by a pinned hook" : nil
    end

    def linked?(hook, project_root)
      found = candidate(command_words(hook))
      return false unless found

      expanded = expand(found.first, project_root: project_root, home: Dir.home, plugin_root: hook.plugin_root)
      located = locate(expanded, project_root)
      located ? File.symlink?(located) : false
    end

    def editability(hook, hooks:, project_root: nil)
      verdict(hook_refusal(hook) || script_refusal(hook, hooks, project_root))
    end

    module Trail
      module_function

      def emit(ports, name, payload)
        ports.events.emit(name, payload)
        true
      rescue StandardError
        false
      end

      def announce_delete(ports, plan, plan_id, via, at)
        deleted = plan.deleted
        return unless deleted

        emit(
          ports, "ordonnateur.hook.deleted",
          {
            "harness" => deleted["harness"], "scope" => plan.scope, "hook_id" => deleted["hook_id"],
            "event" => deleted["event"], "plan_id" => plan_id, "via" => via
          }
        )
        record(
          ports, kind: "deleted", hook: deleted["hook"], via: via, at: at,
          detail: { "plan_id" => plan_id, "command" => deleted["hook"].command }
        )
      end

      def facade(ports)
        unless defined?(Ordonnateur::Provenance::Facade)
          %w[provenance/facade provenance].each do |name|
            require_relative name
            break
          rescue LoadError
            next
          end
        end
        return nil unless defined?(Ordonnateur::Provenance::Facade)

        Ordonnateur::Provenance::Facade.for(ports: ports, settings: Rplugin::Settings.for(ROOT))
      end

      def record(ports, kind:, hook:, via:, at: nil, detail: {})
        store = facade(ports)
        return false unless store

        event = {
          "id" => SecureRandom.hex(8), "at" => (at || Time.now).utc.iso8601, "kind" => kind, "hook_id" => hook.id,
          "harness" => hook.harness, "scope" => hook.scope, "plugin" => hook.plugin, "event" => hook.event,
          "source_file" => hook.source_file, "basis" => "ordonnateur", "via" => via, "detail" => detail
        }
        store.record(events: [event])
        true
      rescue Rplugin::Error, SystemCallError, IOError, KeyError, ArgumentError, NoMethodError, TypeError => e
        warn "ordonnateur: provenance event #{kind} for #{hook.id} not recorded: #{e.class}: #{e.message}"
        false
      end
    end
  end
end
