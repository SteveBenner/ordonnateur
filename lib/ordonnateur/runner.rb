#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "yaml"
require "open3"
require "digest"
require "shellwords"
require "rbconfig"
require "time"
require "securerandom"

require_relative "model"
require_relative "matcher"
require_relative "canonical"
require_relative "card"
require_relative "member"
require_relative "merge"
require_relative "recorder"

module Ordonnateur
  module Runner
    Execution = Struct.new(:stdout, :stderr, :exit, :record, :details, keyword_init: true)

    UNSHOWN = %w[unmatched skipped digest-mismatch].freeze

    module_function

    def main(argv, input: $stdin, out: $stdout, err: $stderr)
      if argv.include?("--help") || argv.include?("-h")
        out.puts "usage: ordonnateur run claude-code <Event> --card <path>"
        return 0
      end
      harness, event, flag, path = argv
      unless harness == "claude-code" && event && flag == "--card" && path
        err.puts "usage: ordonnateur run claude-code <Event> --card <path>"
        return 2
      end
      payload = begin
        parsed = JSON.parse(input.read.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
      execution = execute(event, path, payload, source: "dispatch")
      out.puts JSON.generate(execution.stdout) if execution.stdout
      err.puts execution.stderr if execution.stderr && !execution.stderr.empty?
      out.flush
      Recorder.spawn_detached(execution.record)
      execution.exit
    end

    def now
      Time.now.utc.iso8601
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def failure(event, path, payload, source, reason, started)
      record = {
        "at" => now, "source" => source, "harness" => "claude-code", "scope" => nil, "event" => event,
        "card" => path, "session_id" => payload["session_id"], "total_ms" => ((clock - started) * 1000).round,
        "verdict" => { "decision" => "failure", "blocked" => false }, "members" => []
      }
      Execution.new(stdout: nil, stderr: "ordonnateur: #{reason}; run `ordonnateur lint`", exit: 1, record: record, details: [])
    end

    def execute(event, path, payload, source:, env: {}, cwd: nil)
      started = clock
      card = begin
        Card.read(path)
      rescue Card::Invalid => e
        return failure(event, path, payload, source, e.message, started)
      end
      entry = card["events"][event]
      if entry.nil? || entry["members"].empty?
        return failure(event, path, payload, source, "card #{path} has no entry for #{event}", started)
      end

      current = JSON.parse(JSON.generate(payload))
      entries = []
      stopped = false
      entry["members"].each do |member|
        entries << run_member(event, member, payload, current, entry, stopped, env, cwd)
        stopped = true if entry["stop_on_block"] && entries.last[:ran] && Member.blocking?(entries.last)
        chain(event, current, entries.last)
      end
      merged = Merge.call(event, entries)
      record = build_record(event, path, card, payload, source, started, merged, entries)
      Execution.new(stdout: merged[:stdout], stderr: merged[:stderr], exit: merged[:exit], record: record, details: entries)
    end

    def run_member(event, member, payload, current, entry, stopped, env, cwd)
      base = { id: member["id"], ran: false, exit: nil, ms: 0, stdout_bytes: 0, stderr: "", plain: "", json: nil }
      timeout = member["hook"]["timeout"]
      timeout = Model.default_timeout(event) unless timeout.is_a?(Numeric)
      base[:timeout_s] = timeout
      base[:command] = member["hook"]["command"]
      return base.merge(outcome: "skipped") if stopped

      field = Model::MATCHER_FIELD[event]
      if field && !Matcher.matches?(member["matcher"], payload[field])
        return base.merge(outcome: "unmatched")
      end
      return base.merge(outcome: "digest-mismatch") unless Card.digest_ok?(member)

      result = Member.run(member["hook"], JSON.generate(current), timeout, env: env, cwd: cwd)
      base.merge(Member.interpret(event, result)).merge(ran: true)
    end

    def chain(event, current, entry)
      json = entry[:json]
      return unless json

      hso = Member.hso(json)
      if event == "PreToolUse" && hso.key?("updatedInput")
        current["tool_input"] = hso["updatedInput"]
      elsif event == "PostToolUse" && hso.key?("updatedToolOutput")
        current["tool_response"] = hso["updatedToolOutput"]
      end
    end

    def build_record(event, path, card, payload, source, started, merged, entries)
      stdout = merged[:stdout] || {}
      decision = stdout.dig("hookSpecificOutput", "permissionDecision") || stdout["decision"]
      blocked = merged[:exit] == 2 || %w[deny block].include?(decision) || stdout["continue"] == false
      {
        "at" => now, "source" => source, "harness" => "claude-code", "scope" => card["scope"], "event" => event,
        "card" => path, "session_id" => payload["session_id"], "total_ms" => ((clock - started) * 1000).round,
        "verdict" => { "decision" => decision, "blocked" => blocked },
        "members" => entries.map { |entry| member_record(entry) }
      }
    end

    def member_record(entry)
      {
        "id" => entry[:id], "ms" => entry[:ms], "exit" => entry[:exit], "outcome" => entry[:outcome],
        "timeout_s" => entry[:timeout_s], "stdout_bytes" => entry[:stdout_bytes],
        "stderr_head" => entry[:stderr].to_s[0, 200]
      }
    end
  end
end
