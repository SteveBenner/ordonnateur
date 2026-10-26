#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "open3"
require "digest"

require_relative "../model"
require_relative "../overlay"

module Ordonnateur
  module Harnesses
    module ClaudeCode
      Source = Struct.new(:scope, :path, :data, :text, :exists, keyword_init: true)
      Plugin = Struct.new(:id, :name, :marketplace, :install_path, :version, :enabled, keyword_init: true)

      MANAGED_PATHS = {
        "linux" => "/etc/claude-code/managed-settings.json",
        "macos" => "/Library/Application Support/ClaudeCode/managed-settings.json"
      }.freeze

      module_function

      def name = "claude-code"

      def config_dir
        value = ENV["CLAUDE_CONFIG_DIR"]
        File.expand_path(value && !value.empty? ? value : "~/.claude")
      end

      def project_root(dir = nil)
        base = File.expand_path(dir || Dir.pwd)
        out, status = Open3.capture2("git", "-C", base, "rev-parse", "--show-toplevel", err: File::NULL)
        top = out.strip
        status.success? && !top.empty? ? top : base
      rescue SystemCallError
        base
      end

      def managed_path
        RbConfig::CONFIG["host_os"].to_s.include?("darwin") ? MANAGED_PATHS["macos"] : MANAGED_PATHS["linux"]
      end

      def settings_path(scope, root)
        case scope
        when "managed" then managed_path
        when "user" then File.join(config_dir, "settings.json")
        when "project" then File.join(root, ".claude", "settings.json")
        when "local" then File.join(root, ".claude", "settings.local.json")
        else raise Usage, "unknown scope #{scope}"
        end
      end

      def card_path(scope, root)
        case scope
        when "user" then File.join(config_dir, "ordonnateur.yml")
        when "local" then File.join(state_home, "ordonnateur", "cards", "#{Digest::SHA256.hexdigest(File.expand_path(root))[0, 16]}.local.yml")
        else raise Usage, "scope must be user or local"
        end
      end

      def state_file_path
        value = ENV["CLAUDE_CONFIG_DIR"]
        value && !value.empty? ? File.join(value, ".claude.json") : File.expand_path("~/.claude.json")
      end

      def state_home
        value = ENV["XDG_STATE_HOME"]
        File.join(value && !value.empty? ? value : File.join(Dir.home, ".local", "state"), "rplugin")
      end

      def managed_only?(sources)
        managed = sources.find { |source| source.scope == "managed" }
        managed ? managed.data["allowManagedHooksOnly"] == true : false
      end

      def plugin_cache_dir
        File.join(config_dir, "plugins", "cache")
      end

      def installed_plugins_path
        File.join(config_dir, "plugins", "installed_plugins.json")
      end

      def read_text(path)
        overlaid, text = Overlay.read(path)
        return text if overlaid

        File.file?(path) ? File.read(path) : nil
      rescue SystemCallError, IOError => e
        raise HarnessFileError, "#{path} is unreadable: #{e.message}"
      end

      def parse_settings(path, text)
        return {} if text.nil? || text.strip.empty?

        data = JSON.parse(text)
        raise HarnessFileError, "#{path} is not a JSON object" unless data.is_a?(Hash)

        data
      rescue JSON::ParserError => e
        raise HarnessFileError, "#{path} does not parse: #{e.message.lines.first.to_s.strip}"
      end

      def read_source(scope, path)
        text = read_text(path)
        Source.new(scope: scope, path: path, data: parse_settings(path, text), text: text, exists: !text.nil?)
      end

      def mode_of(path)
        File.file?(path) ? File.stat(path).mode & 0o7777 : nil
      end

      def write_file(path, text, mode: nil)
        Rplugin::AtomicFile.write(path, text, mode: mode)
      end

      def settings_sources(root)
        seen = []
        Model::SCOPE_ORDER.filter_map do |scope|
          path = settings_path(scope, root)
          expanded = File.expand_path(path)
          next if seen.include?(expanded)

          seen << expanded
          read_source(scope, path)
        end
      end

      def enabled_plugins(sources)
        merged = {}
        %w[user project local].each do |scope|
          source = sources.find { |s| s.scope == scope }
          flags = source && source.data["enabledPlugins"]
          merged.merge!(flags) if flags.is_a?(Hash)
        end
        merged
      end

      def plugins(sources, notes)
        path = installed_plugins_path
        text = read_text(path)
        return [] if text.nil?

        data = JSON.parse(text)
        flags = enabled_plugins(sources)
        list = data.is_a?(Hash) && data["plugins"].is_a?(Hash) ? data["plugins"] : {}
        list.flat_map do |id, entries|
          name, marketplace = id.split("@", 2)
          Array(entries).filter_map { |entry| entry["installPath"] if entry.is_a?(Hash) }.uniq.map do |install|
            Plugin.new(id: id, name: name, marketplace: marketplace, install_path: install,
                       version: Array(entries).find { |e| e.is_a?(Hash) && e["installPath"] == install }["version"],
                       enabled: flags[id] == true)
          end
        end
      rescue JSON::ParserError, SystemCallError => e
        notes << "#{path} skipped: #{e.message.lines.first.to_s.strip}"
        []
      end

      def plugin_hook_trees(plugin, notes)
        trees = []
        hooks_json = File.join(plugin.install_path, "hooks", "hooks.json")
        trees << load_tree(hooks_json, notes) if File.file?(hooks_json)
        manifest = File.join(plugin.install_path, ".claude-plugin", "plugin.json")
        if File.file?(manifest)
          declared = begin
            JSON.parse(File.read(manifest))["hooks"]
          rescue JSON::ParserError, SystemCallError => e
            notes << "#{manifest} skipped: #{e.message.lines.first.to_s.strip}"
            nil
          end
          Array(declared.is_a?(Hash) ? [declared] : declared).each do |item|
            if item.is_a?(Hash)
              trees << { path: manifest, text: nil, tree: tree_of(item) }
            elsif item.is_a?(String)
              file = File.expand_path(item, plugin.install_path)
              trees << load_tree(file, notes) if File.file?(file) && file != hooks_json
            end
          end
        end
        trees.compact
      end

      def load_tree(path, notes)
        text = File.read(path)
        { path: path, text: text, tree: tree_of(JSON.parse(text)) }
      rescue JSON::ParserError, SystemCallError => e
        notes << "#{path} skipped: #{e.message.lines.first.to_s.strip}"
        nil
      end

      def tree_of(object)
        return {} unless object.is_a?(Hash)

        object["hooks"].is_a?(Hash) ? object["hooks"] : object
      end

      def hooks_from(tree, scope:, path:, text:, plugin: nil)
        return [] unless tree.is_a?(Hash)

        lines = text ? text.lines : []
        cursor = 0
        tree.flat_map do |event, groups|
          next [] unless groups.is_a?(Array)

          groups.each_with_index.flat_map do |group, group_index|
            next [] unless group.is_a?(Hash) && group["hooks"].is_a?(Array)

            group["hooks"].each_with_index.filter_map do |handler, handler_index|
              next unless handler.is_a?(Hash)

              line, cursor = locate(lines, handler["command"], cursor)
              Model::Hook.new(
                harness: name, scope: scope, source_file: path, event: event, matcher: group["matcher"],
                hook: handler, line: line, group_index: group_index, handler_index: handler_index,
                plugin: plugin&.id, plugin_root: plugin&.install_path, plugin_enabled: plugin ? plugin.enabled : true
              )
            end
          end
        end
      end

      def locate(lines, command, cursor)
        return [nil, cursor] unless command.is_a?(String) && !lines.empty?

        needle = JSON.generate(command)
        index = (cursor...lines.length).find { |i| lines[i].include?(needle) }
        index ? [index + 1, index + 1] : [nil, cursor]
      end

      def watch_files(loaded)
        files = loaded[:sources].map(&:path)
        files << installed_plugins_path
        loaded[:plugins].select(&:enabled).each do |plugin|
          files << File.join(plugin.install_path, "hooks", "hooks.json")
          files << File.join(plugin.install_path, ".claude-plugin", "plugin.json")
        end
        files
      end

      def load(root)
        notes = []
        sources = settings_sources(root)
        hooks = sources.flat_map do |source|
          hooks_from(source.data["hooks"], scope: source.scope, path: source.path, text: source.text)
        end
        plugin_list = plugins(sources, notes)
        plugin_list.each do |plugin|
          plugin_hook_trees(plugin, notes).each do |entry|
            hooks.concat(hooks_from(entry[:tree], scope: "plugin", path: entry[:path], text: entry[:text], plugin: plugin))
          end
        end
        { sources: sources, plugins: plugin_list, hooks: hooks, notes: notes }
      end
    end
  end
end
