#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "digest"
require "time"

require_relative "event"
require_relative "hints"
require_relative "facade"

module Ordonnateur
  module Provenance
    module Observer
      DISABLED_STATUSES = %w[disabled disabled-plugin].freeze
      PROJECT_SCOPES = %w[project local workspace].freeze
      POSITION = %w[harness scope plugin event source_file group_index handler_index].freeze

      module_function

      def scope_key(harness:, scope:, project: nil)
        root = project.to_s.empty? ? "" : realpath(project)
        [harness, scope, root].join("|")
      end

      def each_scope(hooks, project:, user: true)
        groups = Array(hooks).group_by { |hook| PROJECT_SCOPES.include?(hook.scope) ? "project" : "user" }
        scopes = []
        scopes << "user" if user
        scopes << "project" if project
        scopes.each do |scope|
          key = scope_key(harness: "all", scope: scope, project: scope == "project" ? project : nil)
          yield scope, key, groups.fetch(scope, [])
        end
      end

      def call(ports:, settings:, hooks:, scope_key:, via:, at: Time.now.utc)
        facade = Facade.for(ports: ports, settings: settings)
        return [] unless facade.enabled?

        previous = facade.snapshot(scope_key: scope_key)
        stamp = Event.iso(at)
        current = {}
        Array(hooks).each { |hook| current[hook.id] ||= hook }
        events = []
        rows = {}
        first_pass = previous.empty?
        consumed = {}

        current.each do |id, hook|
          row = row_for(hook, stamp)
          before = previous[id]
          if before
            if before["present"] == false
              events << build(hook, "reappeared", via, at, { "fingerprint" => row["fingerprint"] })
              rows[id] = row
            elsif before["enabled"] != row["enabled"]
              kind = row["enabled"] ? "enabled" : "disabled"
              events << build(hook, kind, via, at, { "status" => hook.status, "plugin_enabled" => hook.plugin_enabled })
              rows[id] = row
            else
              rows[id] = before.merge(row.slice(*POSITION))
            end
            next
          end

          origin = first_pass ? nil : match_changed(previous, current, consumed, row)
          if origin
            consumed[origin] = true
            events << build(
              hook, "changed", via, at,
              { "from_hook_id" => origin, "from_fingerprint" => previous[origin]["fingerprint"],
                "to_fingerprint" => row["fingerprint"] }
            )
          else
            events << build(hook, "first_seen", via, at, { "hints" => Hints.for(hook) })
          end
          rows[id] = row
        end

        previous.each do |id, before|
          next if current.key?(id) || consumed[id]

          if before["present"] == false
            rows[id] = before
            next
          end
          events << disappeared(id, before, via, at)
          rows[id] = before.merge("present" => false, "last_seen_at" => stamp)
        end

        return [] if events.empty? && rows == previous

        facade.record(events: events) unless events.empty?
        facade.store_snapshot(scope_key: scope_key, rows: rows)
        events
      end

      def row_for(hook, stamp)
        {
          "fingerprint" => hook.digest,
          "enabled" => enabled?(hook),
          "last_seen_at" => stamp,
          "present" => true,
          "harness" => hook.harness,
          "scope" => hook.scope,
          "plugin" => hook.plugin,
          "event" => hook.event,
          "source_file" => hook.source_file,
          "group_index" => hook.group_index,
          "handler_index" => hook.handler_index
        }
      end

      def enabled?(hook)
        hook.plugin_enabled != false && !DISABLED_STATUSES.include?(hook.status.to_s)
      end

      def match_changed(previous, current, consumed, row)
        previous.each do |id, before|
          next if consumed[id] || current.key?(id) || before["present"] == false
          next if before["fingerprint"] == row["fingerprint"]
          next unless POSITION.all? { |name| before[name] == row[name] }

          return id
        end
        nil
      end

      def build(hook, kind, via, at, detail)
        Event.build(
          kind: kind, hook_id: hook.id, harness: hook.harness, scope: hook.scope, plugin: hook.plugin,
          event: hook.event, source_file: hook.source_file, via: via, detail: detail, at: at
        )
      end

      def disappeared(id, before, via, at)
        Event.build(
          kind: "disappeared", hook_id: id, harness: before["harness"], scope: before["scope"],
          plugin: before["plugin"], event: before["event"], source_file: before["source_file"], via: via,
          detail: { "fingerprint" => before["fingerprint"] }, at: at
        )
      end

      def realpath(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path.to_s)
      end
    end
  end
end
