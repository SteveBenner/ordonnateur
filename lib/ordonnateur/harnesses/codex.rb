#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"

require_relative "../model"
require_relative "../toml_lite"
require_relative "claude_code"

module Ordonnateur
  module Harnesses
    module Codex
      MANAGED_PATH = "/etc/codex/requirements.toml"

      module_function

      def name = "codex"

      def home
        value = ENV["CODEX_HOME"]
        File.expand_path(value && !value.empty? ? value : "~/.codex")
      end

      def snake(event)
        event.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
      end

      def read_text(path)
        File.file?(path) ? File.read(path) : nil
      rescue SystemCallError, IOError => e
        raise HarnessFileError, "#{path} is unreadable: #{e.message}"
      end

      def parse_json_hooks(path, text)
        data = JSON.parse(text)
        ClaudeCode.tree_of(data)
      rescue JSON::ParserError => e
        raise HarnessFileError, "#{path} does not parse: #{e.message.lines.first.to_s.strip}"
      end

      def hooks_from_toml(parsed, scope:, path:, plugin: nil)
        hooks = []
        parsed[:hooks].each do |event, groups|
          groups.each_with_index do |group, group_index|
            group[:hooks].each_with_index do |handler, handler_index|
              hooks << Model::Hook.new(
                harness: name, scope: scope, source_file: path, event: event, matcher: group[:matcher],
                hook: handler, line: group[:handler_lines][handler_index] || group[:line],
                group_index: group_index, handler_index: handler_index,
                plugin: plugin, plugin_enabled: true
              )
            end
          end
        end
        hooks
      end

      def hooks_from_json(path, text, scope:, plugin: nil, plugin_root: nil)
        tree = parse_json_hooks(path, text)
        found = ClaudeCode.hooks_from(tree, scope: scope, path: path, text: text)
        found.each do |hook|
          hook.harness = name
          hook.plugin = plugin
          hook.plugin_root = plugin_root
          hook.plugin_enabled = true
          hook.refresh_identity
        end
        found
      end

      def trust_key(hook)
        "#{hook.source_file}:#{snake(hook.event)}:#{hook.group_index}:#{hook.handler_index}"
      end

      def apply_trust(hooks, state)
        hooks.each do |hook|
          key = trust_key(hook)
          entry = state[key]
          hook.trust = { "key" => key, "state" => entry }
          hook.status =
            if entry && entry["enabled"] == false then "disabled"
            elsif entry && entry["trusted_hash"] then "trust-recorded"
            else "untrusted"
            end
        end
      end

      def read_layer(scope, dir)
        toml_path = File.join(dir, "config.toml")
        json_path = File.join(dir, "hooks.json")
        toml_text = read_text(toml_path)
        json_text = read_text(json_path)
        parsed = toml_text ? TomlLite.parse(toml_text) : { hooks: {}, state: {}, plugins: {}, warnings: [] }
        toml_hooks = hooks_from_toml(parsed, scope: scope, path: toml_path)
        json_hooks = json_text ? hooks_from_json(json_path, json_text, scope: scope) : []
        hooks = json_hooks + toml_hooks
        apply_trust(hooks, parsed[:state])
        keys = hooks.map { |hook| trust_key(hook) }
        {
          scope: scope, dir: dir, toml_path: toml_path, json_path: json_path, parsed: parsed,
          hooks: hooks, toml_count: toml_hooks.length, json_count: json_hooks.length,
          stale: parsed[:state].keys.reject { |key| keys.include?(key) }
        }
      end

      def read_managed
        text = read_text(MANAGED_PATH)
        return nil if text.nil?

        parsed = TomlLite.parse(text)
        hooks = hooks_from_toml(parsed, scope: "managed", path: MANAGED_PATH)
        hooks.each { |hook| hook.status = "managed" }
        {
          scope: "managed", dir: File.dirname(MANAGED_PATH), toml_path: MANAGED_PATH, json_path: nil,
          parsed: parsed, hooks: hooks, toml_count: hooks.length, json_count: 0, stale: []
        }
      end

      def newest_version_dir(base)
        return nil unless File.directory?(base)

        names = Dir.children(base).reject { |entry| entry.start_with?(".") }
                   .select { |entry| File.directory?(File.join(base, entry)) }
        best = names.max_by do |entry|
          Gem::Version.correct?(entry) ? Gem::Version.new(entry) : Gem::Version.new("0")
        end
        best && File.join(base, best)
      end

      def plugin_hooks(user_layer, notes)
        return [] unless user_layer

        user_layer[:parsed][:plugins].flat_map do |id, entry|
          next [] unless entry["enabled"] == true

          plugin_name, marketplace = id.split("@", 2)
          version_dir = newest_version_dir(File.join(home, "plugins", "cache", marketplace.to_s, plugin_name))
          next [] unless version_dir

          path = File.join(version_dir, "hooks", "hooks.json")
          text = read_text(path)
          next [] unless text

          found = hooks_from_json(path, text, scope: "plugin", plugin: id, plugin_root: version_dir)
          found.each { |hook| hook.status = "unknown" }
          found
        rescue HarnessFileError => e
          notes << e.message
          []
        end
      end

      def watch_files(loaded)
        files = loaded[:layers].flat_map { |layer| [layer[:toml_path], layer[:json_path]].compact }
        files + loaded[:hooks].select { |hook| hook.scope == "plugin" }.map(&:source_file)
      end

      def load(root)
        notes = []
        layers = []
        layers << read_managed
        layers << read_layer("user", home)
        layers << read_layer("project", File.join(root, ".codex")) unless File.expand_path(File.join(root, ".codex")) == home
        layers.compact!
        user = layers.find { |layer| layer[:scope] == "user" }
        plugin_list = plugin_hooks(user, notes)
        hooks = layers.flat_map { |layer| layer[:hooks] } + plugin_list
        { layers: layers, hooks: hooks, notes: notes }
      end
    end
  end
end
