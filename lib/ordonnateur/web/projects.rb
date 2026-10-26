#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "fileutils"
require "json"

require_relative "../harnesses/claude_code"

module Ordonnateur
  module Web
    class Projects
      MAX_DISCOVERED = 500
      MAX_PINNED = 200
      MAX_STATE_BYTES = 64 * 1024 * 1024

      def initialize(settings:)
        @settings = settings
      end

      def self.path
        File.join(Web.dir, "projects.json")
      end

      def pinned
        data = JSON.parse(File.read(self.class.path))
        list = data.is_a?(Hash) ? data["pinned"] : nil
        list.is_a?(Array) ? list.select { |item| item.is_a?(String) } : []
      rescue SystemCallError, JSON::ParserError
        []
      end

      def save_pinned(list)
        valid = list.is_a?(Array) && list.all?(String)
        raise Failure.new(422, "invalid", "pinned must be a list of absolute directory paths") unless valid
        raise Failure.new(422, "invalid", "pinned holds at most #{MAX_PINNED} entries") if list.length > MAX_PINNED

        list.each do |path|
          unless path.start_with?("/") && !path.include?("\0") && File.directory?(path)
            raise Failure.new(422, "invalid", "#{path.inspect} is not an absolute path to an existing directory")
          end
        end
        unique = list.uniq
        Web.ensure_dir
        Rplugin::AtomicFile.write(self.class.path, JSON.generate({ "pinned" => unique }), mode: 0o600)
        unique
      end

      def list
        notes = []
        found = {}
        discovered(notes).each { |root| add(found, root, "discovered") }
        @settings.get("web.projects").to_s.split(":").reject(&:empty?).each { |root| add(found, root, "setting", notes) }
        pinned.each { |root| add(found, root, "pinned", notes) }
        projects = found.values.map { |entry| describe(entry) }
        projects.sort_by! { |item| [item["name"], item["root"]] }
        { "projects" => projects, "notes" => notes }
      end

      private

      def key_for(root)
        File.realpath(root)
      rescue SystemCallError
        File.expand_path(root)
      end

      def add(found, root, source, notes = nil)
        key = key_for(root)
        entry = (found[key] ||= { root: key, sources: [] })
        entry[:sources] << source unless entry[:sources].include?(source)
        return if notes.nil? || File.directory?(key)

        reason = root.start_with?("/") ? "is not a directory" : "is not an absolute path"
        note = "#{root} #{reason}"
        notes << note unless notes.include?(note)
      end

      def describe(entry)
        root = entry[:root]
        settings_path = Harnesses::ClaudeCode.settings_path("local", root)
        card_path = Harnesses::ClaudeCode.card_path("local", root)
        directory = File.directory?(root)
        {
          "root" => root,
          "name" => File.basename(root),
          "sources" => entry[:sources],
          "local_hooks" => directory ? local_hook_count(settings_path) : 0,
          "local_card" => directory && File.file?(card_path)
        }
      end

      def local_hook_count(path)
        source = Harnesses::ClaudeCode.read_source("local", path)
        tree = source.data["hooks"]
        return 0 unless tree.is_a?(Hash)

        tree.values.sum do |groups|
          next 0 unless groups.is_a?(Array)

          groups.sum { |group| group.is_a?(Hash) && group["hooks"].is_a?(Array) ? group["hooks"].count { |item| item.is_a?(Hash) } : 0 }
        end
      rescue HarnessFileError
        0
      end

      def discovered(notes)
        return [] unless @settings.on?("web.discover")

        path = Harnesses::ClaudeCode.state_file_path
        unless File.file?(path)
          notes << "#{path} was not found; no projects were discovered"
          return []
        end
        if File.size(path) > MAX_STATE_BYTES
          notes << "#{path} is larger than 64 MiB and was skipped"
          return []
        end
        data = JSON.parse(File.read(path))
        keys = data.is_a?(Hash) && data["projects"].is_a?(Hash) ? data["projects"].keys : nil
        if keys.nil?
          notes << "#{path} has no projects object; no projects were discovered"
          return []
        end
        keys.select { |root| root.is_a?(String) && root.start_with?("/") && File.directory?(root) && local_work?(root) }.first(MAX_DISCOVERED)
      rescue SystemCallError, JSON::ParserError => e
        notes << "#{path} was skipped: #{e.message.lines.first.to_s.strip}"
        []
      end

      def local_work?(root)
        return true if File.file?(Harnesses::ClaudeCode.card_path("local", root))

        text = File.read(Harnesses::ClaudeCode.settings_path("local", root))
        JSON.parse(text).then { |data| data.is_a?(Hash) && data["hooks"].is_a?(Hash) }
      rescue SystemCallError, JSON::ParserError
        false
      end
    end
  end
end
