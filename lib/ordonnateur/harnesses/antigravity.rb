#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "digest"
require "json"
require "open3"
require "strscan"

require_relative "../model"
require_relative "../overlay"
require_relative "claude_code"

module Ordonnateur
  module Harnesses
    module Antigravity
      LEDGER_SCHEMA = "ordonnateur.antigravity-ledger/v1"
      MANIFESTS = [
        "plugin.json", File.join(".antigravity-plugin", "plugin.json"), File.join(".gemini-plugin", "plugin.json")
      ].freeze
      INT32 = (-2**31)..(2**31 - 1)
      ASK_DECISIONS = %w[ask force_ask deny_unless_prior_grant].freeze
      PROCEED_DECISIONS = ["allow", "auto_approve", ""].freeze
      REASON_LIMIT = 160

      module_function

      def name = "antigravity"

      def home
        value = ENV["RPLUGIN_ANTIGRAVITY_HOME"]
        File.expand_path(value && !value.empty? ? value : "~/.gemini")
      end

      def config_dir
        File.join(home, "config")
      end

      def global_path
        File.join(config_dir, "hooks.json")
      end

      def config_json_path
        File.join(config_dir, "config.json")
      end

      def mode_of(path)
        File.file?(path) ? File.stat(path).mode & 0o7777 : nil
      end

      def read_text(path)
        overlaid, text = Overlay.read(path)
        return text if overlaid

        File.file?(path) ? File.read(path) : nil
      rescue SystemCallError, IOError => e
        raise HarnessFileError, "#{path} is unreadable: #{e.message}"
      end

      def strict_violation(text)
        scanner = StringScanner.new(text)
        last = nil
        until scanner.eos?
          if scanner.skip(/"(?:[^"\\]|\\.)*"/m)
            last = '"'
          elsif scanner.skip(/\s+/)
            next
          elsif scanner.check(%r{/})
            return "comments are not allowed in strict JSON"
          else
            char = scanner.getch
            return "trailing comma is not allowed in strict JSON" if ["]", "}"].include?(char) && last == ","

            last = char
          end
        end
        nil
      end

      def lenient(text)
        scanner = StringScanner.new(text)
        out = +""
        comma = nil
        until scanner.eos?
          if (chunk = scanner.scan(/"(?:[^"\\]|\\.)*"/m))
            out << chunk
            comma = nil
          elsif scanner.skip(%r{//[^\n]*}) || scanner.skip(%r{/\*.*?\*/}m)
            next
          elsif (chunk = scanner.scan(/\s+/))
            out << chunk
          else
            char = scanner.getch
            out[comma] = " " if comma && ["]", "}"].include?(char)
            comma = char == "," ? out.length : nil
            out << char
          end
        end
        out
      end

      def plain(value)
        case value
        when Hash then value.each_with_object({}) { |(key, item), out| out[key] = plain(item) }
        when Array then value.map { |item| plain(item) }
        else value
        end
      end

      def recording_class(duplicates)
        counter = 0
        Class.new(Hash) do
          define_method(:initialize) do |*args|
            super(*args)
            counter += 1
            @top = counter == 1
          end

          define_method(:[]=) do |key, value|
            duplicates << key if @top && key?(key) && !duplicates.include?(key)
            super(key, value)
          end
        end
      end

      def clip(message)
        text = message.to_s.lines.first.to_s.strip
        text.length > REASON_LIMIT ? "#{text[0, REASON_LIMIT]}..." : text
      end

      def parse(_path, text)
        duplicates = []
        if text.nil? || text.strip.empty?
          return { data: nil, error: "the file is empty", duplicates: duplicates, json: false }
        end

        violation = strict_violation(text)
        source = violation ? lenient(text) : text
        data = begin
          plain(JSON.parse(source, object_class: recording_class(duplicates)))
        rescue JSON::ParserError => e
          reason = violation || "does not parse: #{clip(e.message)}"
          return { data: nil, error: reason, duplicates: duplicates, json: false }
        end
        { data: data, error: violation || structure_error(data), duplicates: duplicates, json: true }
      end

      def structure_error(data)
        return "top level must be a JSON object" unless data.is_a?(Hash)

        data.each do |spec_name, spec|
          return "hook #{spec_name.inspect} is not an object" unless spec.is_a?(Hash)

          if spec.key?("enabled") && ![true, false].include?(spec["enabled"])
            return "hook #{spec_name.inspect}: enabled must be a boolean"
          end

          spec.each do |event, entries|
            next unless Model::ANTIGRAVITY_EVENTS.include?(event)

            problem = event_error(spec_name, event, entries)
            return problem if problem
          end
        end
        nil
      end

      def event_error(spec_name, event, entries)
        where = "hook #{spec_name.inspect} #{event}"
        return "#{where} must be an array" unless entries.is_a?(Array)

        entries.each do |entry|
          return "#{where} holds an entry that is not an object" unless entry.is_a?(Hash)

          if Model::ANTIGRAVITY_TOOL_EVENTS.include?(event)
            if entry.key?("matcher") && !entry["matcher"].is_a?(String)
              return "#{where}: matcher must be a string"
            end
            next unless entry.key?("hooks")
            return "#{where}: hooks must be an array" unless entry["hooks"].is_a?(Array)

            entry["hooks"].each do |handler|
              return "#{where} holds a handler that is not an object" unless handler.is_a?(Hash)

              problem = handler_error(where, handler)
              return problem if problem
            end
          else
            problem = handler_error(where, entry)
            return problem if problem
          end
        end
        nil
      end

      def handler_error(where, handler)
        type = handler["type"]
        return "#{where}: type must be a string" if handler.key?("type") && !type.is_a?(String)

        if handler.key?("timeout") && !(handler["timeout"].is_a?(Integer) && INT32.cover?(handler["timeout"]))
          return "#{where}: timeout must be an integer number of seconds"
        end

        case type
        when nil, "command"
          command = handler["command"]
          return "#{where}: a command handler needs a non-empty command" unless command.is_a?(String) && !command.empty?
        when "prompt"
          return "#{where}: a prompt handler cannot have a command" if handler.key?("command")
        else
          return "#{where}: hook type #{type.inspect} is not supported"
        end
        nil
      end

      def read_json_object(path)
        text = read_text(path)
        return [nil, nil] if text.nil?

        data = JSON.parse(text)
        [data.is_a?(Hash) ? data : nil, text]
      rescue JSON::ParserError
        [nil, text]
      end

      def project_dirs(project_root, start_dir)
        root = File.expand_path(project_root)
        dir = File.expand_path(start_dir || project_root)
        dirs = []
        loop do
          dirs << dir
          break if dir == root || dir == File.dirname(dir)

          dir = File.dirname(dir)
        end
        dirs
      end

      def workspace_roots(project_root, start_dir)
        project_dirs(project_root, start_dir).flat_map do |dir|
          Model::ANTIGRAVITY_DOT_DIRS.map { |dot| File.join(dir, dot) }.select { |path| File.directory?(path) }
        end
      end

      def workspace_files(project_root, start_dir)
        workspace_roots(project_root, start_dir).map { |root| File.join(root, "hooks.json") }.select { |path| File.file?(path) }
      end

      def manifest_of(dir)
        MANIFESTS.map { |relative| File.join(dir, relative) }.find { |path| File.file?(path) }
      end

      def plugin_dir?(dir)
        File.directory?(dir) && !manifest_of(dir).nil?
      end

      def children(dir)
        Dir.children(dir).sort.map { |child| File.join(dir, child) }.select { |path| File.directory?(path) }
      rescue SystemCallError
        []
      end

      def entry_directory(root, raw, project_root)
        beside = File.expand_path(raw, File.dirname(root))
        return beside if File.directory?(beside)

        fallback = File.expand_path(raw, project_root)
        File.directory?(fallback) ? fallback : nil
      end

      def plugin_dirs(roots, notes, project_root: nil)
        found = []
        seen = []
        add = lambda do |path, root|
          real = File.realpath(path)
          next if seen.include?(real)

          seen << real
          found << { dir: File.basename(path), path: path, root: root, manifest: manifest_of(path) }
        end
        roots.each do |root|
          children(File.join(root, "plugins")).each { |path| add.call(path, root) if plugin_dir?(path) }
          registry = File.join(root, "plugins.json")
          data, = read_json_object(registry)
          next unless data

          notes << "#{registry} has inherits; ordonnateur does not follow them" unless Array(data["inherits"]).empty?
          Array(data["entries"]).each do |entry|
            raw = entry.is_a?(Hash) ? entry["path"] : entry
            next unless raw.is_a?(String) && !raw.empty?

            base = entry_directory(root, raw, project_root || File.dirname(root))
            next unless base

            add.call(base, root) if plugin_dir?(base)
            children(base).each { |path| add.call(path, root) if plugin_dir?(path) }
          end
        end
        found
      end

      def plugin_enabled?(dir, config_json, plugin_json)
        plugins = config_json.is_a?(Hash) ? config_json["plugins"] : nil
        entry = plugins.is_a?(Hash) ? plugins[dir] : nil
        return entry["enabled"] if entry.is_a?(Hash) && [true, false].include?(entry["enabled"])

        !(plugin_json.is_a?(Hash) && plugin_json["disabled"] == true)
      end

      def ledger_path(scope, file_path)
        key = Digest::SHA256.hexdigest(File.expand_path(file_path))[0, 16]
        File.join(ClaudeCode.state_home, "ordonnateur", "antigravity", "#{scope}-#{key}.json")
      end

      def read_ledger(path)
        text = read_text(path)
        return nil if text.nil?

        data = JSON.parse(text)
        return nil unless data.is_a?(Hash) && data["schema"] == LEDGER_SCHEMA && data["events"].is_a?(Hash)

        data
      rescue JSON::ParserError
        nil
      end

      def blank_ledger(file)
        { "schema" => LEDGER_SCHEMA, "file" => file, "events" => {} }
      end

      def dump_ledger(ledger)
        "#{JSON.pretty_generate(ledger)}\n"
      end

      def pinned_reason(hook)
        return nil unless hook.policy_protected

        "is a guard: #{hook.policy_reason || 'protected by the policy engine'}"
      end

      def pinned?(hook)
        !pinned_reason(hook).nil?
      end

      def member?(hook)
        !hook.member_position.nil?
      end

      def status_for(hook, spec_enabled:, file_error:, plugin_enabled:, known:, member:)
        if file_error then "file-skipped"
        elsif !plugin_enabled then "disabled-plugin"
        elsif !known then "ignored-event"
        elsif !spec_enabled then "disabled"
        elsif hook["type"] == "prompt" then "prompt"
        elsif member then "member"
        else "active"
        end
      end

      def hooks_from(data, text, path, scope:, plugin: nil, plugin_root: nil, file_error: nil, plugin_enabled: true,
                     ledger: false)
        return [] unless data.is_a?(Hash)

        lines = text ? text.lines : []
        cursor = 0
        hooks = []
        data.each do |spec_name, spec|
          next unless spec.is_a?(Hash)

          enabled = spec["enabled"] != false
          member_spec = ledger && spec_name == Model::ANTIGRAVITY_MEMBER_SPEC && !plugin
          spec.each do |event, entries|
            next if event == "enabled" || !entries.is_a?(Array)

            known = Model::ANTIGRAVITY_EVENTS.include?(event)
            tool = Model::ANTIGRAVITY_TOOL_EVENTS.include?(event)
            position = 0
            entries.each_with_index do |entry, index|
              next unless entry.is_a?(Hash)

              grouped = (tool || (!known && entry["hooks"].is_a?(Array))) && entry["hooks"].is_a?(Array)
              handlers = grouped ? entry["hooks"].each_with_index.to_a : [[entry, 0]]
              handlers.each do |handler, handler_index|
                next unless handler.is_a?(Hash)

                line, cursor = ClaudeCode.locate(lines, handler["command"], cursor)
                hook = Model::Hook.new(
                  harness: name, scope: scope, source_file: path, event: event,
                  matcher: grouped && entry["matcher"].is_a?(String) ? entry["matcher"] : nil, hook: handler,
                  line: line, group_index: index, handler_index: handler_index, plugin: plugin,
                  plugin_root: plugin_root, plugin_enabled: plugin_enabled, hook_name: spec_name
                )
                hook.member_position = (position += 1) - 1 if member_spec
                hook.status = status_for(
                  handler, spec_enabled: enabled, file_error: file_error, plugin_enabled: plugin_enabled,
                  known: known, member: member_spec
                )
                hooks << hook
              end
            end
          end
        end
        hooks
      end

      def file_entry(path, scope, plugin: nil, plugin_root: nil, enabled: true, notes: [])
        text = read_text(path)
        parsed = parse(path, text)
        ledger_file = scope == "plugin" ? nil : ledger_path(scope, path)
        entry = {
          path: path, scope: scope, plugin: plugin, plugin_root: plugin_root, enabled: enabled, text: text,
          data: parsed[:data], error: parsed[:error], json: parsed[:json], duplicates: parsed[:duplicates],
          ledger_path: ledger_file
        }
        notes << "#{path} is not valid JSON (#{parsed[:error]}); Antigravity skips it" unless parsed[:json]
        entry
      end

      def load(root, start_dir = nil)
        notes = []
        files = []
        ledgers = {}
        watch = [global_path, config_json_path, File.join(config_dir, "plugins.json")]
        config_json, = read_json_object(config_json_path)
        roots = [config_dir] + workspace_roots(root, start_dir || root)
        files << file_entry(global_path, "global", notes: notes) if File.file?(global_path) || Overlay.read(global_path)[0]
        workspace_files(root, start_dir || root).each { |path| files << file_entry(path, "workspace", notes: notes) }
        plugin_dirs(roots, notes, project_root: root).each do |plugin|
          watch << plugin[:manifest] if plugin[:manifest]
          manifest, = plugin[:manifest] ? read_json_object(plugin[:manifest]) : [nil, nil]
          hooks_path = File.join(plugin[:path], "hooks.json")
          unless File.file?(hooks_path)
            nested = File.join(plugin[:path], "hooks", "hooks.json")
            notes << "#{nested} is not loaded by Antigravity; plugins keep hooks.json at the plugin root" if File.file?(nested)
            next
          end
          enabled = plugin_enabled?(plugin[:dir], config_json, manifest)
          files << file_entry(
            hooks_path, "plugin", plugin: plugin[:dir], plugin_root: plugin[:path], enabled: enabled, notes: notes
          )
        end
        hooks = []
        files.each do |entry|
          watch << entry[:path]
          if entry[:ledger_path]
            watch << entry[:ledger_path]
            ledger = read_ledger(entry[:ledger_path])
            ledgers[entry[:path]] = ledger if ledger
          end
          next unless entry[:data]

          hooks.concat(
            hooks_from(
              entry[:data], entry[:text], entry[:path], scope: entry[:scope], plugin: entry[:plugin],
              plugin_root: entry[:plugin_root], file_error: entry[:error], plugin_enabled: entry[:enabled],
              ledger: ledgers.key?(entry[:path]) && !ledgers[entry[:path]]["events"].empty?
            )
          )
        end
        { files: files, hooks: hooks, notes: notes, ledgers: ledgers, watch: watch.uniq, config_json: config_json }
      end

      def watch_files(loaded)
        loaded[:watch]
      end

      def run_hook(hook, payload_json, timeout:, env: {}, cwd: nil)
        result = { returncode: nil, stdout: "", stderr: "", timed_out: false, elapsed_ms: 0, error: nil }
        command = hook.command
        if command.nil? || command.empty?
          result[:error] = "empty command"
          return result
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        options = { pgroup: true }
        options[:chdir] = cwd || File.dirname(hook.source_file)
        begin
          stdin, stdout, stderr, waiter = Open3.popen3(env || {}, "sh", "-c", command, **options)
        rescue SystemCallError, IOError => e
          result[:error] = e.message
          return result
        end
        out_reader = Thread.new { stdout.read.to_s }
        err_reader = Thread.new { stderr.read.to_s }
        writer = Thread.new do
          stdin.write(payload_json)
        rescue SystemCallError, IOError
          nil
        ensure
          begin
            stdin.close
          rescue IOError
            nil
          end
        end
        finished = waiter.join(timeout)
        if finished.nil?
          begin
            Process.kill("KILL", -waiter.pid)
          rescue SystemCallError
            nil
          end
          waiter.join(1)
          result[:timed_out] = true
        else
          result[:returncode] = waiter.value.exitstatus
        end
        writer.join(1)
        result[:stdout] = clean(out_reader.value) if out_reader.join(1)
        result[:stderr] = clean(err_reader.value) if err_reader.join(1)
        result[:elapsed_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        result
      ensure
        [stdout, stderr].each do |io|
          io&.close unless io&.closed?
        end
      end

      def clean(text)
        text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      def parse_output(stdout)
        text = stdout.to_s.strip
        return [nil, "empty stdout"] if text.empty?

        data = JSON.parse(text)
        data.is_a?(Hash) ? [data, nil] : [nil, "stdout is not a JSON object"]
      rescue JSON::ParserError
        [nil, "stdout is not JSON"]
      end

      def outcome_of(outcome, blocked, directive = nil, message = nil)
        { outcome: outcome, blocked: blocked, directive: directive, message: message }
      end

      def interpret(event, result)
        failure = result[:error] || (result[:timed_out] ? "timed out" : nil)
        failure ||= "exited #{result[:returncode]}" unless result[:returncode] == 0
        if event == "PreToolUse"
          return outcome_of("blocked", true, nil, "hook failed closed: #{failure}") if failure

          data, problem = parse_output(result[:stdout])
          return outcome_of("blocked", true, nil, "hook failed closed: #{problem}") unless data

          return decision_outcome(data)
        end
        return outcome_of("warn", false, nil, failure) if failure

        data, = parse_output(result[:stdout])
        return outcome_of("ok", false) unless data

        case event
        when "Stop" then data["decision"] == "continue" ? outcome_of("continue", false, data, "keeps the loop running") : outcome_of("ok", false, data)
        when "PostInvocation" then invocation_outcome(data)
        when "SessionStart", "PreInvocation" then steps_outcome(data)
        else outcome_of("ok", false, data)
        end
      end

      def decision_outcome(data)
        decision = data["decision"].to_s
        reason = data["reason"].is_a?(String) ? data["reason"] : nil
        if decision == "deny"
          outcome_of("blocked", true, data, reason || "denied by the hook")
        elsif ASK_DECISIONS.include?(decision)
          outcome_of("ask", false, data, reason || "asks for permission")
        elsif PROCEED_DECISIONS.include?(decision)
          outcome_of("proceed", false, data, reason)
        else
          outcome_of("proceed", false, data, "unrecognised decision #{decision.inspect}")
        end
      end

      def invocation_outcome(data)
        behavior = data["terminationBehavior"]
        return outcome_of(behavior, false, data, "#{behavior} requested") if %w[force_continue terminate].include?(behavior)

        steps_outcome(data)
      end

      def steps_outcome(data)
        steps = data["injectSteps"]
        count = steps.is_a?(Array) ? steps.length : 0
        return outcome_of("ok", false, data) if count.zero?

        outcome_of("inject", false, data, "#{count} injected step#{count == 1 ? '' : 's'}")
      end
    end
  end
end
