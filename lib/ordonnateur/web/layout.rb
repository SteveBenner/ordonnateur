#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "digest"

require_relative "../canonical"
require_relative "../card"
require_relative "../harnesses/antigravity"
require_relative "../harnesses/hermes"
require_relative "../inventory"
require_relative "../lint"
require_relative "../timings"
require_relative "../watch"

module Ordonnateur
  module Web
    class Layout
      TIMING_KEYS = %w[runs p50 p95 max failures slow near_timeout].freeze

      def initialize(ports:, settings:)
        @ports = ports
        @settings = settings
      end

      def self.finding_id(finding)
        Digest::SHA256.hexdigest([finding["code"], finding["hook"], finding["message"]].join("\0"))[0, 12]
      end

      def slow_ms
        @settings.get("lint.slow_ms")
      end

      def inventory_for(project)
        Inventory.load_full(harness: "all", project: project || Web.empty_root, policy: @ports.policy)
      end

      def timing_rows
        Timings.rows(Timings.records(@ports, 2), slow_ms: slow_ms)
      end

      def fingerprint_of(inventory, rows)
        {
          "config" => Watch.new(ports: @ports, settings: @settings).fingerprint(inventory),
          "timings" => Digest::SHA256.hexdigest(Canonical.json(rows))
        }
      end

      def fingerprint(project)
        fingerprint_of(inventory_for(project), timing_rows)
      end

      def findings(inventory, rows)
        Lint.run(inventory, rows: rows, slow_ms: slow_ms).map { |item| item.merge("id" => self.class.finding_id(item)) }
      end

      def settings_files(project, inventory)
        {
          "user" => Harnesses::ClaudeCode.settings_path("user", inventory.root),
          "local" => project ? Harnesses::ClaudeCode.settings_path("local", inventory.root) : nil,
          "codex" => File.join(Harnesses::Codex.home, "config.toml"),
          "hermes" => Harnesses::Hermes.config_path,
          "antigravity" => {
            "global" => Harnesses::Antigravity.global_path,
            "workspace" => workspace_paths(inventory)
          }
        }
      end

      def workspace_paths(inventory)
        loaded = inventory.antigravity
        return [] unless loaded

        loaded[:files].select { |entry| entry[:scope] == "workspace" }.map { |entry| entry[:path] }
      end

      def pinned_flag(hook)
        case hook.harness
        when "hermes" then Harnesses::Hermes.pinned?(hook)
        when "antigravity" then Harnesses::Antigravity.pinned?(hook)
        end
      end

      def build(project)
        inventory = inventory_for(project)
        rows = timing_rows
        found = findings(inventory, rows)
        by_hook = found.group_by { |item| item["hook"] }
        timings = rows.to_h { |row| [row["id"], row.slice(*TIMING_KEYS)] }
        unguarded = Card.unguarded_map(inventory.root)
        hooks = inventory.hooks.map do |hook|
          pinned = pinned_flag(hook)
          extra = hook.harness == "antigravity" ? { "member" => Harnesses::Antigravity.member?(hook) } : {}
          hook.to_h.merge(extra).merge(
            "guard" => pinned.nil? ? Inventory.guard?(hook, unguarded[hook.scope] || []) : pinned,
            "hard_guard" => pinned.nil? ? (Inventory.hard_guard?(hook) ? true : false) : pinned,
            "effective_timeout" => hook.effective_timeout,
            "findings" => (by_hook[hook.id] || []).map { |item| item["id"] },
            "timing" => timings[hook.id]
          )
        end
        notes = inventory.notes.dup
        cards = %w[user local].to_h do |scope|
          entry = inventory.cards[scope]
          notes << "#{entry[:path]}: #{entry[:error]}" if entry && entry[:error]
          [scope, entry && entry[:card] ? { "path" => entry[:path], "card" => entry[:card] } : nil]
        end
        {
          "fingerprint" => fingerprint_of(inventory, rows),
          "project" => project ? inventory.root : nil,
          "settings_files" => settings_files(project, inventory),
          "hooks" => hooks,
          "cards" => cards,
          "findings" => found,
          "notes" => notes
        }
      end
    end
  end
end
