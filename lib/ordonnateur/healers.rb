#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require_relative "model"
require_relative "card"
require_relative "inventory"
require_relative "takeover"
require_relative "settings_plan"

module Ordonnateur
  module Healers
    Heal = Struct.new(:id, :finding, :hook, :source, :safe, :action, keyword_init: true)
    Prepared = Struct.new(:heal, :entries, :verdicts, :text, :changed, :apply, keyword_init: true)

    CATALOG = {
      "sequence-escaped" => { code: "ORD-ESCAPED", safe: true, action: "add the hook to the end of its event's sequence" },
      "drop-ignored-matcher" => { code: "ORD-MATCHER", safe: true, action: "remove the matcher Claude Code ignores" },
      "drop-duplicate" => { code: "ORD-DUP", safe: true, action: "remove the local copy of an identical handler" },
      "remove-dead" => { code: "ORD-DEAD", safe: false, action: "remove the handler whose program does not exist" }
    }.freeze
    ORDER = CATALOG.keys.freeze

    module_function

    def eligible?(hook, inventory)
      hook.harness == "claude-code" && %w[user local].include?(hook.scope) && hook.plugin.nil? &&
        !hook.status.to_s.start_with?("member#") && !hook.dispatcher? &&
        !Model::GUARD_EVENTS.include?(hook.event) && hook.hook["onFailure"] != "block" && !hook.policy_protected &&
        hook.source_file == Harnesses::ClaudeCode.settings_path(hook.scope, inventory.root)
    end

    def available(findings, inventory)
      found = {}
      findings.each do |finding|
        hook = inventory.hooks.find { |item| item.id == finding["hook"] }
        next unless hook && finding["harness"].to_s == "claude-code"

        heal = heal_for(finding, hook, inventory)
        found[[heal.id, heal.hook.id]] ||= heal if heal
      end
      found.values.sort_by { |heal| [ORDER.index(heal.id), heal.hook.id] }
    end

    def heal_for(finding, hook, inventory)
      id =
        case finding["code"]
        when "ORD-ESCAPED" then "sequence-escaped"
        when "ORD-MATCHER" then finding["severity"] == "info" ? "drop-ignored-matcher" : nil
        when "ORD-DUP" then finding["severity"] == "info" ? "drop-duplicate" : nil
        when "ORD-DEAD" then "remove-dead"
        end
      return nil unless id

      target = id == "drop-duplicate" ? local_copy(hook, inventory) : hook
      return nil unless target && eligible?(target, inventory) && qualifies?(id, target)

      entry = CATALOG.fetch(id)
      Heal.new(id: id, finding: finding["code"], hook: target, source: finding["hook"], safe: entry[:safe], action: entry[:action])
    end

    def qualifies?(id, hook)
      case id
      when "drop-ignored-matcher"
        Model::NO_MATCHER_EVENTS.include?(hook.event) && !Matcher.all?(hook.matcher)
      when "remove-dead", "sequence-escaped"
        hook.type == "command"
      else
        true
      end
    end

    def local_copy(hook, inventory)
      pool = inventory.hooks.select do |item|
        item.harness == "claude-code" && item.plugin.nil? && item.event == hook.event && item.digest == hook.digest &&
          !item.status.to_s.start_with?("member#")
      end
      user = pool.select { |item| item.scope == "user" }
      local = pool.select { |item| item.scope == "local" }
      user.length == 1 && local.length == 1 ? local.first : nil
    end

    def prepare(heal, ports:, project:)
      heal.id == "sequence-escaped" ? prepare_sequence(heal, ports, project) : prepare_settings(heal, ports, project)
    end

    def prepare_sequence(heal, ports, project)
      hook = heal.hook
      takeover = Takeover.new(scope: hook.scope, project: project, ports: ports)
      card = Card.load_if_present(takeover.card_path)
      ids = Card.members(card, hook.event).map { |member| member["id"] }
      ids << hook.id unless ids.include?(hook.id)
      plan = takeover.plan_order(hook.event, ids)
      entries = [
        SettingsPlan::Entry.new(path: plan.settings_path, before: plan.settings_text_before, after: plan.settings_text_after,
                                mode: plan.settings_mode),
        SettingsPlan::Entry.new(path: plan.card_path, before: plan.card_text_before, after: plan.card_text_after, mode: 0o600)
      ].select { |entry| entry.before != entry.after }
      Prepared.new(
        heal: heal, entries: entries, verdicts: plan.verdicts, text: takeover.render(plan), changed: takeover.changed?(plan),
        apply: -> { takeover.apply(plan) }
      )
    end

    def prepare_settings(heal, ports, project)
      hook = heal.hook
      kind = heal.id == "drop-ignored-matcher" ? :drop_matcher : :remove_handler
      planner = SettingsPlan.new(scope: hook.scope, project: project, ports: ports)
      plan = planner.plan_hook_edit(kind, hook)
      Prepared.new(
        heal: heal, entries: plan.entries, verdicts: plan.verdicts, text: planner.render(plan), changed: planner.changed?(plan),
        apply: -> { planner.apply(plan) }
      )
    end
  end
end
