#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "etc"

require_relative "model"
require_relative "inventory"
require_relative "lint"
require_relative "timings"

module Ordonnateur
  module Health
    DIMENSIONS = %w[liveness correctness duplication ordering latency safety integrity freshness].freeze
    LINT_CODES = {
      "liveness" => %w[ORD-DEAD ORD-EVENT ORD-CODEX-DISABLED ORD-CODEX-UNTRUSTED ORD-HERMES-UNALLOWLISTED ORD-AG-DISABLED
                       ORD-AG-SKIPPED ORD-AG-NOHOOKS ORD-HERMES-EVENT ORD-AG-EVENT],
      "correctness" => %w[ORD-MATCHER ORD-HERMES-MATCHER-IGNORED ORD-HERMES-FAILCLOSED-IGNORED ORD-HERMES-ENV ORD-AG-MATCHER
                          ORD-AG-MATCHER-IGNORED ORD-AG-CLAUDE-TOOL ORD-AG-PROMPT ORD-RUN-FAILING],
      "duplication" => %w[ORD-DUP ORD-TWIN ORD-HERMES-DUP ORD-AG-DUPNAME ORD-CODEX-BOTH],
      "ordering" => %w[ORD-ESCAPED ORD-AG-RANDOM-ORDER],
      "latency" => %w[ORD-SLOW ORD-NEARTIMEOUT ORD-SESSIONEND ORD-HERMES-TIMEOUT ORD-AG-TIMEOUT ORD-EVENT-LOAD
                      ORD-GUARD-NO-TIMEOUT],
      "safety" => %w[ORD-PROTECTED ORD-MANAGED-ONLY ORD-HOOK-WRITABLE ORD-GUARD-ASYNC ORD-GUARD-MASKED],
      "integrity" => %w[ORD-CARD ORD-CARD-DIGEST ORD-CODEX-TOML ORD-HERMES-BADENTRY ORD-HERMES-ALLOWLIST ORD-AG-NOTJSON
                        ORD-AG-LEDGER ORD-CONFIG-NOTE],
      "freshness" => %w[ORD-CODEX-STALE-TRUST ORD-HERMES-STALE-CONSENT ORD-PLUGIN-PATH]
    }.freeze
    DIMENSION_OF = LINT_CODES.flat_map { |dimension, codes| codes.map { |code| [code, dimension] } }.to_h.freeze
    SEVERITY_ORDER = %w[error warn info].freeze
    EVENT_LOAD_LIMIT = 12
    RUN_MIN = 8
    INERT = %w[disabled disabled-plugin file-skipped ignored-event dispatcher].freeze
    MASKED = /(\|\|\s*(true|:)|;\s*exit\s+0)\s*\z/.freeze
    CONFIG_FAULT = /pars|unreadable|invalid|malformed|not json|not valid|could not|cannot read/i.freeze

    module_function

    def assess(inventory, findings, records, slow_ms: 2000, harness: "all")
      hooks = Lint.active(inventory.hooks)
      extra = []
      extra.concat(writable(inventory, hooks))
      extra.concat(guard_findings(hooks))
      extra.concat(event_load(hooks))
      extra.concat(run_failing(records, slow_ms))
      extra.concat(config_notes(inventory))
      extra = extra.select { |item| harness == "all" || item["harness"].nil? || item["harness"] == harness }
      all = sort(findings + extra)
      unmapped = all.map { |item| item["code"] }.uniq.reject { |code| DIMENSION_OF.key?(code) }
      { "findings" => all, "dimensions" => dimensions(all), "unmapped_codes" => unmapped }
    end

    def sort(findings)
      findings.sort_by { |item| [SEVERITY_ORDER.index(item["severity"]) || 3, item["code"], item["hook"].to_s] }
    end

    def dimensions(findings)
      DIMENSIONS.map do |name|
        indexes = findings.each_index.select { |index| dimension_for(findings[index]["code"]) == name }
        severities = indexes.map { |index| findings[index]["severity"] }
        status =
          if severities.any? { |severity| Lint::FAILING.include?(severity) } then "unhealthy"
          elsif severities.empty? then "healthy"
          else "watch"
          end
        { "dimension" => name, "status" => status, "count" => indexes.length, "findings" => indexes }
      end
    end

    def dimension_for(code)
      DIMENSION_OF.fetch(code, "integrity")
    end

    def program_path(hook, inventory)
      word = hook.harness == "hermes" ? Lint.hermes_program(hook) : Lint.program_of(hook)
      return nil if word.nil? || word.empty?

      if hook.harness == "antigravity"
        return nil if word.include?("$")

        word = word.sub(/\A~(?=\/|\z)/, Dir.home)
        word = File.expand_path(word, File.dirname(hook.source_file)) if word.include?("/")
      elsif hook.harness != "hermes"
        word = Lint.expand(word, hook, inventory.root)
      end
      return nil if word.include?("$")
      return word if word.include?("/")

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, word) }.find do |path|
        Lint.executable_file?(path)
      end
    end

    def runnable?(hook)
      hook.command && (hook.type.nil? || hook.type == "command") && !INERT.include?(hook.status.to_s) &&
        !hook.status.to_s.start_with?("member#")
    end

    def writable(inventory, hooks)
      by_program = hooks.select { |hook| runnable?(hook) || hook.dispatcher? }.group_by { |hook| program_path(hook, inventory) }
      by_program.filter_map do |path, list|
        next unless path && File.exist?(path)

        problems = write_problems(File.stat(path))
        next if problems.empty?

        used = list.length > 1 ? " (used by #{list.length} hooks)" : ""
        Lint.finding("ORD-HOOK-WRITABLE", "warn", list.first,
                     "program #{path}#{used} is #{problems.join(' and ')}, so someone else can change what runs",
                     "restrict the file's permissions")
      end
    end

    def write_problems(stat)
      problems = []
      problems << "world-writable" if stat.mode.anybits?(0o002)
      problems << "group-writable" if stat.mode.anybits?(0o020) && !private_group?(stat.gid)
      problems << "owned by another user" if stat.uid != Process.euid && stat.uid != 0
      problems
    end

    def private_group?(gid)
      group = Etc.getgrgid(gid)
      user = Etc.getpwuid(Process.euid).name
      group.name == user && (group.mem - [user]).empty?
    rescue ArgumentError
      false
    end

    def guard_hooks(hooks)
      hooks.select do |hook|
        hook.harness == "claude-code" && Model::GUARD_EVENTS.include?(hook.event) && hook.command &&
          !hook.status.to_s.start_with?("member#") && !hook.status.to_s.start_with?("disabled")
      end
    end

    def guard_findings(hooks)
      guard_hooks(hooks).flat_map do |hook|
        found = []
        if hook.hook["async"] == true || hook.hook["asyncRewake"] == true
          found << Lint.finding("ORD-GUARD-ASYNC", "info", hook, "runs async on #{hook.event}, so it cannot block",
                                "remove async if it is meant to guard")
        end
        if MASKED.match?(hook.command.to_s.strip)
          found << Lint.finding("ORD-GUARD-MASKED", "info", hook,
                                "ends in || true or ; exit 0 on #{hook.event}, so a failure cannot block")
        end
        if hook.timeout.nil?
          found << Lint.finding("ORD-GUARD-NO-TIMEOUT", "info", hook,
                                "has no timeout on #{hook.event} and gets the default of #{Model.default_timeout(hook.event)} s",
                                "set a timeout")
        end
        found
      end
    end

    def event_load(hooks)
      pool = hooks.reject do |hook|
        (INERT.include?(hook.status.to_s) && !hook.dispatcher?) || hook.status.to_s.start_with?("member#")
      end
      pool.group_by { |hook| [hook.harness, hook.event] }.filter_map do |(harness, event), list|
        subject, count = busiest(list)
        next unless count > EVENT_LOAD_LIMIT

        Lint.finding("ORD-EVENT-LOAD", "info", event,
                     "#{count} hooks start together on #{event}#{subject.empty? ? '' : " for #{subject}"}", nil, harness: harness)
      end
    end

    def busiest(list)
      values = list.flat_map do |hook|
        Matcher.simple?(hook.matcher) ? Matcher.alternatives(hook.matcher).reject(&:empty?) : []
      end.uniq
      counts = ([""] + values).map do |value|
        [value, list.count { |hook| value.empty? ? Matcher.all?(hook.matcher) : Matcher.matches?(hook.matcher, value) }]
      end
      counts.max_by { |_value, count| count }
    end

    def run_failing(records, slow_ms)
      Timings.rows(records, slow_ms: slow_ms).filter_map do |row|
        next unless row["runs"] >= RUN_MIN && row["failures"] * 4 > row["runs"]

        Lint.finding("ORD-RUN-FAILING", "warn", row["id"],
                     "failed or timed out in #{row['failures']} of #{row['runs']} recorded runs",
                     "run ordonnateur timings and fix the hook", harness: row["harness"])
      end
    end

    def config_notes(inventory)
      inventory.notes.map do |note|
        first = note.to_s[/\A\S+/].to_s
        subject = first.start_with?("/") || first.start_with?("~") ? first.chomp(":") : "configuration"
        severity = CONFIG_FAULT.match?(note.to_s) ? "warn" : "info"
        Lint.finding("ORD-CONFIG-NOTE", severity, subject, note.to_s, nil, harness: nil)
      end
    end
  end
end
