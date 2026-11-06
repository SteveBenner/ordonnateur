#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"

require_relative "model"
require_relative "redact"
require_relative "toml_lite"
require_relative "harnesses/claude_code"
require_relative "harnesses/codex"
require_relative "harnesses/hermes"
require_relative "harnesses/antigravity"

module Ordonnateur
  module SetupScan
    STATE_FILE_LIMIT = 5_000_000
    VALUE_LIMIT = 160
    READ_ERRORS = [SystemCallError, IOError, JSON::ParserError, Ordonnateur::Error, TomlLite::Unreadable].freeze

    module_function

    def call(project:, inventory:)
      notes = []
      root = inventory.root || Harnesses::ClaudeCode.project_root(project)
      document = {
        "claude_code" => guarded(notes, "Claude Code") { claude(inventory, root, notes) },
        "codex" => guarded(notes, "Codex") { codex(inventory, notes) },
        "hermes" => guarded(notes, "Hermes") { hermes(inventory) },
        "antigravity" => guarded(notes, "Antigravity") { antigravity(inventory) },
        "notes" => notes
      }
      document["notes"] = notes.map { |note| Redact.text(note) }
      Redact.tree(document)
    end

    def guarded(notes, label)
      yield
    rescue *READ_ERRORS => e
      notes << "#{label} could not be read: #{e.message.to_s.lines.first.to_s.strip}"
      nil
    end

    def claude(inventory, root, notes)
      loaded = inventory.claude
      return nil unless loaded

      {
        "settings" => loaded[:sources].map { |source| source_summary(source) },
        "plugins" => loaded[:plugins].map { |plugin| plugin_summary(plugin, inventory) },
        "agents" => names(File.join(Harnesses::ClaudeCode.config_dir, "agents"), notes, files: true) +
                    names(File.join(root, ".claude", "agents"), notes, files: true),
        "skills" => names(File.join(Harnesses::ClaudeCode.config_dir, "skills"), notes, files: false) +
                    names(File.join(root, ".claude", "skills"), notes, files: false),
        "mcp_servers" => mcp(root, notes)
      }
    end

    def source_summary(source)
      data = source.data.is_a?(Hash) ? source.data : {}
      summary = data.reject { |key, _| key == "hooks" }
      summary["hooks"] = hook_counts(data["hooks"])
      { "scope" => source.scope, "path" => source.path, "exists" => source.exists, "settings" => summary }
    end

    def hook_counts(tree)
      return {} unless tree.is_a?(Hash)

      tree.each_with_object({}) do |(event, groups), memo|
        memo[event] = groups.is_a?(Array) ? groups.sum { |group| group.is_a?(Hash) ? Array(group["hooks"]).length : 0 } : 0
      end
    end

    def plugin_summary(plugin, inventory)
      events = inventory.hooks.select { |hook| hook.plugin == plugin.id }.map(&:event).uniq
      { "id" => plugin.id, "enabled" => plugin.enabled, "version" => plugin.version, "hook_events" => events }
    end

    def names(dir, notes, files:)
      return [] unless File.directory?(dir)

      entries = Dir.children(dir).sort
      entries = files ? entries.select { |name| name.end_with?(".md") }.map { |name| name.delete_suffix(".md") } : entries.select { |name| File.directory?(File.join(dir, name)) }
      entries.first(200)
    rescue SystemCallError => e
      notes << "#{dir} could not be read: #{e.class.name}"
      []
    end

    def mcp(root, notes)
      project_file = File.join(root, ".mcp.json")
      found = {}
      found["project"] = server_names(project_file, "mcpServers", notes, limit: nil)
      state = Harnesses::ClaudeCode.state_file_path
      found["user_state"] = server_names(state, "mcpServers", notes, limit: STATE_FILE_LIMIT)
      found
    end

    def server_names(path, key, notes, limit:)
      return [] unless File.file?(path)

      if limit && File.size(path) > limit
        notes << "#{path} is larger than #{limit} bytes and was skipped"
        return []
      end
      data = JSON.parse(File.read(path))
      servers = data.is_a?(Hash) ? data[key] : nil
      servers.is_a?(Hash) ? servers.keys.sort.first(100) : []
    rescue JSON::ParserError, SystemCallError => e
      notes << "#{path} was skipped: #{e.class.name}"
      []
    end

    def codex(inventory, notes)
      loaded = inventory.codex
      return nil unless loaded

      path = File.join(Harnesses::Codex.home, "config.toml")
      text = Harnesses::Codex.read_text(path)
      notes << "#{path} was not found" if text.nil?
      top = {}
      tables = []
      scan_toml(text.to_s, top, tables)
      {
        "path" => path, "top_level" => top, "tables" => tables.first(100),
        "plugins" => plugin_ids(text), "hook_count" => loaded[:hooks].length
      }
    end

    def scan_toml(text, top, tables)
      in_table = false
      text.each_line do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        table = stripped.match(/\A\[+([^\]]+)\]+\z/)
        if table
          in_table = true
          tables << table[1]
        elsif !in_table && (pair = stripped.match(/\A([A-Za-z0-9_.-]+)\s*=\s*(.+)\z/))
          top[pair[1]] = pair[2][0, VALUE_LIMIT]
        end
      end
    end

    def plugin_ids(text)
      return [] if text.nil?

      TomlLite.parse(text)[:plugins].keys.first(100)
    rescue TomlLite::Unreadable
      []
    end

    def hermes(inventory)
      loaded = inventory.hermes
      return nil unless loaded

      data = loaded[:data].is_a?(Hash) ? loaded[:data] : {}
      summary = data.reject { |key, _| key == "hooks" }
      {
        "path" => loaded[:config_path], "settings" => summary, "hook_counts" => hook_counts(data["hooks"]),
        "opt_in" => loaded[:opt_in]
      }
    end

    def antigravity(inventory)
      loaded = inventory.antigravity
      return nil unless loaded

      files = loaded[:files].map do |file|
        specs = file[:data].is_a?(Hash) ? file[:data].keys : []
        { "path" => file[:path], "scope" => file[:scope], "plugin" => file[:plugin], "valid" => file[:json], "specs" => specs.first(50) }
      end
      { "config" => loaded[:config_json], "hook_files" => files }
    end
  end
end
