#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "member"

module Ordonnateur
  module Merge
    CONTEXT_EVENTS = %w[
      SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure SubagentStart Stop SubagentStop
    ].freeze
    PLAIN_CONTEXT_EVENTS = %w[SessionStart UserPromptSubmit].freeze
    EXIT_TWO_MESSAGE_EVENTS = %w[SubagentStart SessionStart PostCompact].freeze
    PRECEDENCE = %w[deny defer ask allow].freeze
    SHOWN = %w[ok block deny ask defer allow error timeout].freeze

    module_function

    def call(event, entries)
      pieces = entries.select { |entry| SHOWN.include?(entry[:outcome]) }
      verdict = {}
      specific = {}
      common(verdict, pieces, event, entries)
      send_event(event, pieces, verdict, specific)
      context(event, pieces, specific)
      unless specific.empty?
        verdict["hookSpecificOutput"] = { "hookEventName" => event }.merge(specific)
      end
      if event == "PreCompact"
        blockers = pieces.select { |entry| Member.blocking?(entry) && decision_block?(entry) }
        unless blockers.empty?
          reasons = blockers.map { |entry| Member.reason_of(entry) }.reject(&:empty?).join("\n")
          return { stdout: nil, stderr: reasons, exit: 2 }
        end
      end
      { stdout: verdict.empty? ? nil : verdict, stderr: nil, exit: 0 }
    end

    def json_of(entry)
      entry[:json] || {}
    end

    def pick(entry, key)
      json = json_of(entry)
      value = Member.hso(json)[key]
      value.nil? ? json[key] : value
    end

    def text_value(value)
      value.is_a?(String) && !value.empty? ? value : nil
    end

    def decision_block?(entry)
      return true if entry[:exit] == 2 && entry[:json].nil?

      json_of(entry)["decision"] == "block"
    end

    def short_id(entry)
      entry[:id].to_s.split(":").last
    end

    def common(verdict, pieces, event, entries)
      verdict["continue"] = false if pieces.any? { |entry| json_of(entry)["continue"] == false }
      stop = pieces.filter_map { |entry| text_value(json_of(entry)["stopReason"]) }.first
      verdict["stopReason"] = stop if stop && verdict["continue"] == false
      lines = []
      entries.each do |entry|
        if entry[:outcome] == "digest-mismatch"
          lines << "ordonnateur: #{short_id(entry)} skipped: card entry edited by hand; run ordonnateur lint"
          next
        end
        next unless SHOWN.include?(entry[:outcome])

        message = text_value(json_of(entry)["systemMessage"])
        lines << message if message
        if %w[error timeout].include?(entry[:outcome])
          first = entry[:stderr].to_s.lines.first.to_s.strip
          lines << "ordonnateur: #{short_id(entry)} #{entry[:outcome]} (exit #{entry[:exit].inspect}): #{first}"
        end
        if EXIT_TWO_MESSAGE_EVENTS.include?(event) && entry[:exit] == 2 && !entry[:stderr].to_s.empty?
          lines << entry[:stderr]
        end
      end
      verdict["systemMessage"] = lines.join("\n") unless lines.empty?
      verdict["suppressOutput"] = true if pieces.any? { |entry| json_of(entry)["suppressOutput"] == true }
    end

    def context(event, pieces, specific)
      return unless CONTEXT_EVENTS.include?(event)

      parts = []
      pieces.each do |entry|
        added = text_value(Member.hso(json_of(entry))["additionalContext"])
        parts << added if added
        parts << entry[:plain] if PLAIN_CONTEXT_EVENTS.include?(event) && text_value(entry[:plain])
        parts << entry[:stderr] if event == "PostToolUseFailure" && entry[:exit] == 2 && !entry[:stderr].to_s.empty?
      end
      specific["additionalContext"] = parts.join("\n\n") unless parts.empty?
    end

    def collect(pieces, key)
      pieces.filter_map do |entry|
        json = json_of(entry)
        hso = Member.hso(json)
        if hso.key?(key) then [hso[key], :inside]
        elsif json.key?(key) then [json[key], :top]
        end
      end
    end

    def place(verdict, specific, key, value, items)
      target = items.all? { |_, location| location == :top } ? verdict : specific
      target[key] = value
    end

    def blocks(verdict, pieces, fallback: false)
      blockers = pieces.select { |entry| decision_block?(entry) }
      return if blockers.empty?

      verdict["decision"] = "block"
      reasons = blockers.map do |entry|
        reason = Member.reason_of(entry)
        reason.empty? && fallback ? "ordonnateur: #{short_id(entry)} blocked" : reason
      end.reject(&:empty?)
      verdict["reason"] = reasons.join("\n") unless reasons.empty?
    end

    def send_event(event, pieces, verdict, specific)
      case event
      when "SessionStart" then session_start(pieces, verdict, specific)
      when "UserPromptSubmit" then user_prompt(pieces, verdict, specific)
      when "PreToolUse" then pre_tool_use(pieces, specific)
      when "PostToolUse" then post_tool_use(pieces, verdict, specific)
      when "Stop", "SubagentStop" then blocks(verdict, pieces, fallback: true)
      end
    end

    def first_text(verdict, specific, pieces, key)
      items = collect(pieces, key).select { |value, _| text_value(value) }
      place(verdict, specific, key, items.first[0], items) unless items.empty?
    end

    def any_true(verdict, specific, pieces, key)
      items = collect(pieces, key).select { |value, _| value == true }
      place(verdict, specific, key, true, items) unless items.empty?
    end

    def session_start(pieces, verdict, specific)
      first_text(verdict, specific, pieces, "sessionTitle")
      first_text(verdict, specific, pieces, "initialUserMessage")
      items = collect(pieces, "watchPaths")
      paths = items.flat_map { |value, _| Array(value) }.uniq
      place(verdict, specific, "watchPaths", paths, items) unless paths.empty?
      any_true(verdict, specific, pieces, "reloadSkills")
    end

    def user_prompt(pieces, verdict, specific)
      blocks(verdict, pieces)
      first_text(verdict, specific, pieces, "sessionTitle")
      any_true(verdict, specific, pieces, "suppressOriginalPrompt")
    end

    def decision_of(entry)
      return "deny" if entry[:exit] == 2 && entry[:json].nil?

      entry[:json] ? Member.pre_decision(entry[:json]) : nil
    end

    def pre_tool_use(pieces, specific)
      decisions = pieces.filter_map { |entry| (d = decision_of(entry)) && [entry, d] }
      winner = PRECEDENCE.find { |name| decisions.any? { |_, d| d == name } }
      if winner
        specific["permissionDecision"] = winner
        reasons = decisions.select { |_, d| d == winner }.map { |entry, _| Member.reason_of(entry) }.reject(&:empty?)
        specific["permissionDecisionReason"] = reasons.join("\n") unless reasons.empty?
      end
      updated = pieces.filter_map { |entry| Member.hso(json_of(entry))["updatedInput"] }.last
      specific["updatedInput"] = updated unless updated.nil?
    end

    def post_tool_use(pieces, verdict, specific)
      blocks(verdict, pieces)
      items = collect(pieces, "classifierContext").select { |value, _| text_value(value) }
      place(verdict, specific, "classifierContext", items.map(&:first).join("\n\n"), items) unless items.empty?
      %w[updatedToolOutput updatedMCPToolOutput].each do |key|
        found = collect(pieces, key).reject { |value, _| value.nil? }
        place(verdict, specific, key, found.last[0], found) unless found.empty?
      end
    end
  end
end
