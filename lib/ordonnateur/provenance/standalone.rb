#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

require_relative "event"

module Ordonnateur
  module Provenance
    class StoreError < Rplugin::Error
    end

    class Standalone < Rplugin::Ports::Base
      ROTATE_BYTES = 8 * 1024 * 1024
      READ_CAP_BYTES = 16 * 1024 * 1024
      ROTATED_PATTERN = /\Aevents\.jsonl\.\d/.freeze
      EVENTS_FILE = "events.jsonl"
      SNAPSHOTS_FILE = "snapshots.json"
      LOCK_FILE = ".lock"
      DEFAULT_LIMIT = 200

      def record(events:)
        list = Array(events).filter_map { |item| Event.normalize(item) }
        return 0 if list.empty?

        with_lock do
          rotate
          path = events_path
          FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
          text = list.map { |item| "#{JSON.generate(item)}\n" }.join
          text = "\n#{text}" if File.exist?(path) && !ends_with_newline?(path)
          File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.syswrite(text) }
        end
        list.length
      end

      def history(hook_id: nil, since: nil, limit: DEFAULT_LIMIT)
        floor = since.nil? ? nil : Event.time_of(since)
        cap = [limit.to_i, 1].max
        skipped = 0
        found = []
        read_lines.reverse_each do |line|
          item = parse(line)
          if item.nil?
            skipped += 1
            next
          end
          next if hook_id && item["hook_id"] != hook_id.to_s

          if floor
            at = Event.time_of(item["at"])
            next if at.nil? || at < floor
          end
          found << item
        end
        @skipped = skipped
        found.first(cap)
      end

      def snapshot(scope_key:)
        rows = read_snapshots[scope_key.to_s]
        rows.is_a?(Hash) ? rows : {}
      end

      def store_snapshot(scope_key:, rows:)
        with_lock do
          all = read_snapshots
          all[scope_key.to_s] = JSON.parse(JSON.generate(rows || {}))
          path = snapshots_path
          FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
          Rplugin::AtomicFile.write(path, JSON.generate(all), mode: 0o600)
        end
        true
      end

      def status
        notes = []
        if @skipped.to_i.positive?
          notes << "#{@skipped} unreadable line#{'s' if @skipped != 1} skipped in #{EVENTS_FILE}"
        elsif truncated_tail?
          notes << "the last line of #{EVENTS_FILE} is truncated and is skipped"
        end
        notes << "#{EVENTS_FILE} is unreadable (#{@unreadable})" if @unreadable
        oversized = oversized_files
        notes << "#{oversized.join(', ')} above #{READ_CAP_BYTES} bytes and not read" unless oversized.empty?
        older = [rotated_files.length - 1, 0].max
        notes << "#{older} older rotated event file#{'s' if older != 1} not read" if older.positive?
        { store: "local", degraded: false, note: notes.empty? ? nil : notes.join("; ") }
      end

      def extension?
        false
      end

      def dir
        File.join(Rplugin::Paths.state_home, "ordonnateur", "provenance")
      end

      private

      def events_path
        File.join(dir, EVENTS_FILE)
      end

      def snapshots_path
        File.join(dir, SNAPSHOTS_FILE)
      end

      def rotated_files
        names = Dir.children(dir).select { |name| name.match?(ROTATED_PATTERN) }
        names.sort_by { |name| [name[/\Aevents\.jsonl\.(\d+T\d+Z)/, 1].to_s, name[/Z\.(\d+)\z/, 1].to_i] }
             .map { |name| File.join(dir, name) }
      rescue SystemCallError
        []
      end

      def readable_event_files
        newest = rotated_files.last
        [newest, events_path].compact.select { |path| File.file?(path) && File.size(path) <= READ_CAP_BYTES }
      end

      def oversized_files
        [rotated_files.last, events_path].compact.select { |path| File.file?(path) && File.size(path) > READ_CAP_BYTES }
                                          .map { |path| File.basename(path) }
      rescue SystemCallError
        []
      end

      def read_lines
        @unreadable = nil
        lines = []
        readable_event_files.each do |path|
          lines.concat(File.binread(path).force_encoding(Encoding::UTF_8).split("\n"))
        end
        lines.reject { |line| line.strip.empty? }
      rescue SystemCallError => e
        @unreadable = "#{e.class.name}: #{e.message.to_s[0, 160]}"
        warn("ordonnateur: #{EVENTS_FILE} could not be read (#{@unreadable})") unless @unreadable_warned
        @unreadable_warned = true
        []
      end

      def parse(line)
        data = JSON.parse(line)
        data.is_a?(Hash) && data["kind"] && data["hook_id"] ? data : nil
      rescue JSON::ParserError, EncodingError
        nil
      end

      def read_snapshots
        path = snapshots_path
        return {} unless File.file?(path)
        return set_aside!(path, "is above #{READ_CAP_BYTES} bytes") if File.size(path) > READ_CAP_BYTES

        data = JSON.parse(File.read(path))
        return set_aside!(path, "does not hold a JSON object") unless data.is_a?(Hash)

        data
      rescue JSON::ParserError
        set_aside!(path, "is not valid JSON")
      rescue SystemCallError => e
        raise StoreError, "#{SNAPSHOTS_FILE} could not be read (#{e.class.name}); provenance state was left as it is"
      end

      def set_aside!(path, reason)
        stamp = Time.now.utc.strftime("%Y%m%dT%H%M%S%LZ")
        target = "#{path}.corrupt-#{stamp}"
        counter = 1
        while File.exist?(target)
          target = "#{path}.corrupt-#{stamp}.#{counter}"
          counter += 1
        end
        File.rename(path, target)
        raise StoreError, "#{SNAPSHOTS_FILE} #{reason}; it was kept as #{target} and the next observation starts fresh"
      rescue Errno::ENOENT
        raise StoreError, "#{SNAPSHOTS_FILE} #{reason} and was already set aside; the next observation starts fresh"
      rescue SystemCallError => e
        raise StoreError, "#{SNAPSHOTS_FILE} #{reason} and could not be set aside (#{e.class.name})"
      end

      def rotate
        path = events_path
        return unless File.size?(path).to_i >= ROTATE_BYTES

        stamp = Time.now.utc.strftime("%Y%m%dT%H%M%S%LZ")
        target = "#{path}.#{stamp}"
        counter = 1
        while File.exist?(target)
          target = "#{path}.#{stamp}.#{counter}"
          counter += 1
        end
        File.rename(path, target)
      end

      def ends_with_newline?(path)
        return true if File.size(path).zero?

        File.open(path, "rb") do |file|
          file.seek(-1, IO::SEEK_END)
          file.read(1) == "\n"
        end
      end

      def truncated_tail?
        path = events_path
        File.file?(path) && !ends_with_newline?(path)
      rescue SystemCallError
        false
      end

      def with_lock
        FileUtils.mkdir_p(dir, mode: 0o700)
        File.open(File.join(dir, LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end
    end
  end
end
