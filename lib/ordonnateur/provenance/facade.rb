#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "fileutils"
require "json"
require "timeout"

require_relative "event"
require_relative "standalone"

module Ordonnateur
  module Provenance
    class Facade
      SPOOL_FILE = "spool.jsonl"
      SPOOL_LOCK_FILE = ".spool.lock"
      SPOOL_CAP_BYTES = 8 * 1024 * 1024
      SPOOL_READ_CAP_BYTES = 16 * 1024 * 1024
      ADAPTER_CALL_CAP_S = 4
      BACKENDS = %w[local extension].freeze
      OFF_NOTE = "provenance is off"
      NO_ADAPTER_NOTE = "no extension adapter"
      DEGRADED_EVENT = "ordonnateur.provenance.degraded"

      def self.for(ports:, settings:)
        new(ports: ports, settings: settings)
      end

      def initialize(ports:, settings:)
        @ports = ports
        @settings = settings
        @local = Standalone.new(plugin_id: "ordonnateur")
        @degraded_note = nil
      end

      def enabled?
        mode != :off
      end

      def extension?
        mode == :extension
      end

      def record(events:)
        case mode
        when :off then 0
        when :extension then record_extension(events)
        else @local.record(events: events)
        end
      end

      def history(hook_id: nil, since: nil, limit: 200)
        case mode
        when :off then []
        when :extension then history_extension(hook_id, since, limit)
        else @local.history(hook_id: hook_id, since: since, limit: limit)
        end
      end

      def snapshot(scope_key:)
        case mode
        when :off then {}
        when :extension then snapshot_extension(scope_key)
        else @local.snapshot(scope_key: scope_key)
        end
      end

      def store_snapshot(scope_key:, rows:)
        case mode
        when :off then true
        when :extension then store_snapshot_extension(scope_key, rows)
        else @local.store_snapshot(scope_key: scope_key, rows: rows)
        end
      end

      def status
        case mode
        when :off
          { store: backend_name == "extension" ? "extension" : "local", degraded: false, note: OFF_NOTE }
        when :missing
          { store: "local", degraded: true, note: @degraded_note || NO_ADAPTER_NOTE }
        when :extension
          pending = spool_lines.length
          degraded = pending.positive? || !@degraded_note.nil?
          note = degraded ? (@degraded_note || "events are spooled locally until the store answers") : nil
          if @spool_unreadable
            note = [note, "the spool is unreadable (#{@spool_unreadable})"].compact.join("; ")
            degraded = true
          end
          if spool_oversized?
            note = [note, "the spool is above #{SPOOL_READ_CAP_BYTES} bytes and is not read"].compact.join("; ")
            degraded = true
          end
          { store: "extension", degraded: degraded, note: note }
        else
          @local.status
        end
      end

      private

      def mode
        @mode ||= resolve_mode
      end

      def resolve_mode
        return :off unless provenance_on?
        return :local unless backend_name == "extension"

        @adapter = adapter_port
        @adapter ? :extension : :missing
      end

      def provenance_on?
        @settings.on?("provenance.enabled")
      end

      def backend_name
        env = ENV.fetch("ORDONNATEUR_PROVENANCE_BACKEND", "")
        return env if BACKENDS.include?(env)

        value = @settings.get("provenance.backend").to_s
        BACKENDS.include?(value) ? value : "local"
      end

      def adapter_port
        port = @ports.provenance
        port.extension? == true ? port : nil
      rescue Rplugin::PortUnavailable
        nil
      rescue StandardError => e
        @degraded_note = "the extension adapter failed to load (#{e.class.name}: #{e.message.to_s[0, 160]}); provenance stays in the local file"
        warn("ordonnateur: #{@degraded_note}")
        nil
      end

      def record_extension(events)
        list = Array(events).filter_map { |item| Event.normalize(item) }
        return 0 if list.empty?

        guarded(
          -> { list.length.tap { spool_events(list) } },
          -> { replay_spool && @adapter.record(events: list) && list.length }
        )
      end

      def history_extension(hook_id, since, limit)
        guarded(
          -> { spooled_history(hook_id, since, limit) },
          -> { replay_spool && @adapter.history(hook_id: hook_id, since: since, limit: limit) }
        )
      end

      def snapshot_extension(scope_key)
        guarded(
          -> { spooled_snapshot(scope_key) || @local.snapshot(scope_key: scope_key) },
          -> { replay_spool && @adapter.snapshot(scope_key: scope_key) }
        )
      end

      def store_snapshot_extension(scope_key, rows)
        guarded(
          -> { spool_snapshot(scope_key, rows) },
          -> { replay_spool && @adapter.store_snapshot(scope_key: scope_key, rows: rows) }
        )
      end

      def guarded(fallback, attempt)
        result = Timeout.timeout(ADAPTER_CALL_CAP_S) { attempt.call }
        @degraded_note = nil
        settle
        result
      rescue StandardError, Timeout::Error => e
        note_outage(e)
        fallback.call
      end

      def settle
        with_spool_lock do
          lines = spool_lines
          write_spool([]) if !lines.empty? && lines.all? { |line| line["t"] == "outage" }
        end
      rescue StandardError => e
        warn("ordonnateur: could not clear the provenance outage marker (#{e.class.name}: #{e.message.to_s[0, 160]})")
      end

      def note_outage(error)
        reason = "#{error.class.name}: #{error.message.to_s[0, 160]}"
        @degraded_note = "provenance store unreachable (#{reason}); events are spooled locally"
        first = spool_lines.empty?
        append_spool([{ "t" => "outage", "at" => Event.iso(Time.now.utc) }]) if first
        announce(reason) if first
      rescue StandardError => e
        warn("ordonnateur: could not record the provenance outage (#{e.class.name}: #{e.message.to_s[0, 160]})")
      end

      def announce(reason)
        @ports.events.emit(DEGRADED_EVENT, { "backend" => "extension", "reason" => reason })
      rescue StandardError
        nil
      end

      def spool_path
        File.join(@local.dir, SPOOL_FILE)
      end

      def spool_oversized?
        File.file?(spool_path) && File.size(spool_path) > SPOOL_READ_CAP_BYTES
      rescue SystemCallError
        false
      end

      def spool_lines
        return [] unless File.file?(spool_path)
        return [] if spool_oversized?

        File.read(spool_path).split("\n").filter_map do |line|
          data = JSON.parse(line)
          data.is_a?(Hash) ? data : nil
        rescue JSON::ParserError
          nil
        end
      rescue SystemCallError => e
        note_unreadable_spool(e)
        []
      end

      def note_unreadable_spool(error)
        return if @spool_unreadable

        @spool_unreadable = "#{error.class.name}: #{error.message.to_s[0, 160]}"
        warn("ordonnateur: the provenance spool is unreadable (#{@spool_unreadable})")
      end

      def with_spool_lock
        FileUtils.mkdir_p(@local.dir, mode: 0o700)
        File.open(File.join(@local.dir, SPOOL_LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def write_spool(lines)
        path = spool_path
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        if lines.empty?
          File.truncate(path, 0) if File.exist?(path)
          return
        end
        Rplugin::AtomicFile.write(path, lines.map { |line| "#{JSON.generate(line)}\n" }.join, mode: 0o600)
      end

      def append_spool(lines)
        with_spool_lock do
          next if File.size?(spool_path).to_i >= SPOOL_CAP_BYTES

          text = lines.map { |line| "#{JSON.generate(line)}\n" }.join
          File.open(spool_path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.syswrite(text) }
        end
      end

      def spool_events(list)
        append_spool(list.map { |item| { "t" => "event", "e" => item } })
      end

      def spool_snapshot(scope_key, rows)
        with_spool_lock do
          kept = spool_lines.reject { |line| line["t"] == "snapshot" && line["scope_key"] == scope_key.to_s }
          kept << { "t" => "snapshot", "scope_key" => scope_key.to_s, "rows" => rows }
          write_spool(kept)
        end
        true
      end

      def spooled_snapshot(scope_key)
        line = spool_lines.reverse.find { |item| item["t"] == "snapshot" && item["scope_key"] == scope_key.to_s }
        line && line["rows"].is_a?(Hash) ? line["rows"] : nil
      end

      def spooled_history(hook_id, since, limit)
        floor = since.nil? ? nil : Event.time_of(since)
        spooled = spool_lines.select { |line| line["t"] == "event" }.map { |line| line["e"] }.reverse
        spooled = spooled.select { |item| hook_id.nil? || item["hook_id"] == hook_id.to_s }
        spooled = spooled.select { |item| (at = Event.time_of(item["at"])) && at >= floor } if floor
        (spooled + @local.history(hook_id: hook_id, since: since, limit: limit)).first([limit.to_i, 1].max)
      end

      def replay_spool
        with_spool_lock do
          lines = spool_lines
          next true if lines.empty?

          markers = lines.select { |line| line["t"] == "outage" }
          work = lines - markers
          until work.empty?
            if work.first["t"] == "event"
              batch = work.take_while { |line| line["t"] == "event" }
              @adapter.record(events: batch.map { |line| line["e"] })
              work = work.drop(batch.length)
            else
              head = work.first
              @adapter.store_snapshot(scope_key: head["scope_key"], rows: head["rows"]) if head["t"] == "snapshot"
              work = work.drop(1)
            end
            write_spool(markers + work)
          end
          true
        end
      end
    end
  end
end
