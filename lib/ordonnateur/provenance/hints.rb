#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "json"
require "time"

require_relative "event"

module Ordonnateur
  module Provenance
    module Hints
      MAX_RECORD_BYTES = 4 * 1024 * 1024

      module_function

      def for(hook, record_path: nil)
        found = []
        record = plugin_record(hook, record_path)
        found << record if record
        mtime = file_mtime(hook)
        found << mtime if mtime
        found
      end

      def plugin_record(hook, record_path)
        return nil if hook.plugin.to_s.empty?

        entries = installed_entries(record_path)[hook.plugin.to_s]
        return nil unless entries.is_a?(Array)

        entry = entries.find { |item| item.is_a?(Hash) && hook.plugin_root && item["installPath"] == hook.plugin_root } ||
                entries.find { |item| item.is_a?(Hash) && item["installedAt"] }
        at = entry && Event.time_of(entry["installedAt"])
        return nil unless at

        { "basis" => "plugin_record", "at" => Event.iso(at), "note" => "installedAt in the plugin install record; not an observed install" }
      end

      def installed_entries(record_path)
        path = record_path || default_record_path
        return {} unless path && File.file?(path) && File.size(path) <= MAX_RECORD_BYTES

        data = JSON.parse(File.read(path))
        data.is_a?(Hash) && data["plugins"].is_a?(Hash) ? data["plugins"] : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      def default_record_path
        require_relative "../harnesses/claude_code"
        Harnesses::ClaudeCode.installed_plugins_path
      rescue LoadError, NameError, SystemCallError
        File.join(Dir.home, ".claude", "plugins", "installed_plugins.json")
      end

      def file_mtime(hook)
        path = hook.source_file
        return nil if path.to_s.empty? || !File.file?(path)

        { "basis" => "file_mtime", "at" => Event.iso(File.mtime(path)) }
      rescue SystemCallError
        nil
      end
    end
  end
end
