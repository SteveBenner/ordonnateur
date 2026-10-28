#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "shellwords"
require "time"

require_relative "model"
require_relative "inventory"
require_relative "payload"
require_relative "member"
require_relative "merge"
require_relative "runner"
require_relative "recorder"
require_relative "harnesses/hermes"
require_relative "harnesses/antigravity"

module Ordonnateur
  class Fire
    CAP = 2000

    def initialize(ports:, settings:)
      @ports = ports
      @settings = settings
    end

    PLACEHOLDER = "<fire tmpdir>"

    def call(options, out)
      inventory = Inventory.load_full(harness: "all", project: options[:project], policy: @ports.policy)
      targets, event, card_path = resolve(inventory, options)
      commands = targets.map { |hook| command_text(hook) }
      return call_hermes(targets.first, event, commands.first, options, out) if targets.first&.harness == "hermes"
      if targets.first&.harness == "antigravity"
        return call_antigravity(targets.first, event, commands.first, inventory, options, out)
      end

      return run_for_real(targets, commands, card_path, event, options, out) if options[:run]

      payload, cwd = build_payload(event, targets.first, PLACEHOLDER, false, options)
      judge_cwd = options[:cwd] ? File.expand_path(options[:cwd]) : Dir.pwd
      verdicts = commands.map { |command| judge(command, judge_cwd) }
      report = { "event" => event, "cwd" => cwd, "environment" => environment(targets.first, cwd), "commands" => commands,
                 "policy" => verdicts, "payload" => payload }
      plan_output(report, targets, out, options)
    end

    def build_payload(event, sample, tmp, write, options)
      Payload.build(
        event, tmp: tmp, write: write, matcher: sample&.matcher, cwd: options[:cwd],
        payload_file: options[:payload], sets: options[:sets]
      )
    end

    def environment(sample, cwd)
      sample ? Payload.environment(sample, cwd) : { "CLAUDE_PROJECT_DIR" => cwd }
    end

    def run_for_real(targets, commands, card_path, event, options, out)
      Dir.mktmpdir("ordonnateur-fire") do |tmp|
        out.puts "fire tmpdir: #{tmp} (removed when the fire finishes)" unless options[:json]
        payload, cwd = build_payload(event, targets.first, tmp, true, options)
        env = environment(targets.first, cwd)
        verdicts = commands.map { |command| judge(command, cwd) }
        report = { "event" => event, "cwd" => cwd, "environment" => env, "commands" => commands,
                   "policy" => verdicts, "payload" => payload, "tmpdir" => tmp }
        guard_run!(targets, commands, verdicts)
        execute(report, targets, card_path, event, payload, env, cwd, out, options)
      end
      0
    end

    def resolve(inventory, options)
      if options[:event]
        if Model::HERMES_EVENTS.include?(options[:event]) || Model::HERMES_PYTHON_ONLY_EVENTS.include?(options[:event])
          raise Usage, "Hermes has no cards; ordonnateur reorders its hooks in place"
        end
        if Model::ANTIGRAVITY_EVENTS.include?(options[:event]) && !Model::CLAUDE_EVENTS.include?(options[:event])
          raise Usage, "Antigravity has no cards; ordonnateur orders its hooks in hooks.json; fire one hook at a time"
        end

        scope = options[:scope] || "user"
        entry = inventory.cards[scope]
        card = entry && entry[:card]
        raise Usage, "no #{scope} card for #{options[:event]}" unless card && !Card.members(card, options[:event]).empty?

        members = inventory.members.select { |hook| hook.scope == scope && hook.event == options[:event] }
        [members, options[:event], entry[:path]]
      else
        raise Usage, "fire needs a hook or --event" if options[:ref].nil?

        hook = Inventory.resolve(inventory.hooks, options[:ref])
        [[hook], hook.event, nil]
      end
    end

    HERMES_TIMEOUT_DEFAULT = 60
    HERMES_TIMEOUT_MAX = 300

    def call_hermes(hook, event, command, options, out)
      return run_hermes(hook, event, command, options, out) if options[:run]

      payload, cwd = Payload.build_hermes(
        event, hook, tmp: PLACEHOLDER, write: false, cwd: options[:cwd],
        payload_file: options[:payload], sets: options[:sets] || []
      )
      judge_cwd = options[:cwd] ? File.expand_path(options[:cwd]) : Dir.pwd
      report = { "event" => event, "cwd" => cwd, "environment" => Payload.environment_hermes(cwd), "commands" => [command],
                 "policy" => [judge(command, judge_cwd)], "payload" => payload, "hermes" => hermes_state(hook) }
      plan_output(report, [hook], out, options)
    end

    def hermes_state(hook)
      state = hook.status
      { "would_run" => %w[allowlisted auto-accepted].include?(state), "allowlist_state" => state }
    end

    def hermes_line(report)
      state = report["hermes"]
      "hermes would run this hook: #{state['would_run'] ? 'yes' : 'no'} (#{state['allowlist_state']})"
    end

    def hermes_timeout(hook)
      value = hook.effective_timeout
      return HERMES_TIMEOUT_DEFAULT if value < 1

      [value, HERMES_TIMEOUT_MAX].min
    end

    def hermes_outcome(outcome)
      case outcome
      when "blocked" then "block"
      when /timeout/ then "timeout"
      when /error|fail_closed/ then "error"
      else "ok"
      end
    end

    def run_hermes(hook, event, command, options, out)
      Dir.mktmpdir("ordonnateur-fire") do |tmp|
        out.puts "fire tmpdir: #{tmp} (removed when the fire finishes)" unless options[:json]
        payload, cwd = Payload.build_hermes(
          event, hook, tmp: tmp, write: true, cwd: options[:cwd],
          payload_file: options[:payload], sets: options[:sets] || []
        )
        env = Payload.environment_hermes(cwd)
        verdict = judge(command, cwd)
        report = { "event" => event, "cwd" => cwd, "environment" => env, "commands" => [command],
                   "policy" => [verdict], "payload" => payload, "tmpdir" => tmp, "hermes" => hermes_state(hook) }
        if Harnesses::Hermes.pinned?(hook)
          raise Refused, "ordonnateur does not fire #{hook.id}: #{Harnesses::Hermes.pinned_reason(hook)}"
        end

        guard_run!([hook], [command], [verdict])
        execute_hermes(report, hook, event, payload, env, cwd, out, options)
      end
      0
    end

    def execute_hermes(report, hook, event, payload, env, cwd, out, options)
      timeout = hermes_timeout(hook)
      result = Harnesses::Hermes.run_hook(hook, JSON.generate(payload), timeout: timeout, env: env, cwd: cwd)
      verdict = Harnesses::Hermes.interpret(
        event, result, fail_closed: Harnesses::Hermes.fail_closed?(hook.hook, event), command: hook.command
      )
      outcome = verdict[:blocked] ? "blocked" : verdict[:outcome]
      entry = {
        id: hook.id, ran: true, outcome: hermes_outcome(outcome), hermes_outcome: outcome, exit: result[:returncode],
        ms: result[:elapsed_ms], timeout_s: timeout, raw_stdout: result[:stdout], raw_stderr: result[:stderr],
        stdout: result[:stdout], stderr: result[:stderr], stdout_bytes: result[:stdout].to_s.bytesize,
        error: result[:error]
      }
      record = {
        "at" => Time.now.utc.iso8601, "source" => "fire", "harness" => "hermes", "scope" => "user",
        "event" => event, "card" => nil, "session_id" => payload["session_id"], "total_ms" => result[:elapsed_ms],
        "verdict" => { "decision" => verdict[:blocked] ? "block" : (verdict[:directive] && verdict[:directive]["action"]), "blocked" => verdict[:blocked] },
        "members" => [Runner.member_record(entry)]
      }
      store(record)
      print_hermes_run(report, entry, verdict, out, options)
    end

    def print_hermes_run(report, entry, verdict, out, options)
      shown = {
        "id" => entry[:id], "exit" => entry[:exit], "ms" => entry[:ms], "outcome" => entry[:hermes_outcome],
        "stdout" => entry[:raw_stdout].to_s[0, CAP], "stderr" => entry[:raw_stderr].to_s[0, CAP], "error" => entry[:error]
      }
      if options[:json]
        out.puts JSON.pretty_generate(
          report.merge("ran" => true, "members" => [shown], "blocked" => verdict[:blocked], "outcome" => verdict[:outcome],
                       "directive" => verdict[:directive], "message" => verdict[:message])
        )
        return
      end
      out.puts hermes_line(report)
      out.puts "member #{entry[:id]}: exit #{entry[:exit].inspect}, #{entry[:ms]} ms, #{entry[:hermes_outcome]}"
      out.puts "  error: #{entry[:error]}" if entry[:error]
      out.puts "  stdout: #{entry[:raw_stdout].to_s[0, CAP]}" unless entry[:raw_stdout].to_s.empty?
      out.puts "  stderr: #{entry[:raw_stderr].to_s[0, CAP]}" unless entry[:raw_stderr].to_s.empty?
      out.puts "blocked: #{verdict[:blocked] ? 'yes' : 'no'}#{verdict[:message] ? " (#{verdict[:message]})" : ''}"
      out.puts "directive: #{verdict[:directive] ? JSON.generate(verdict[:directive]) : '(none)'}"
      out.puts "ran for real: side effects of this hook happened"
    end

    ANTIGRAVITY_RUNNING = %w[active member prompt].freeze

    def call_antigravity(hook, event, command, inventory, options, out)
      return run_antigravity(hook, event, command, inventory, options, out) if options[:run]

      payload, = Payload.build_antigravity(
        event, hook, tmp: PLACEHOLDER, write: false, cwd: options[:cwd] || inventory.root,
        payload_file: options[:payload], sets: options[:sets] || []
      )
      judge_cwd = options[:cwd] ? File.expand_path(options[:cwd]) : Dir.pwd
      report = { "event" => event, "cwd" => File.dirname(hook.source_file),
                 "environment" => Payload.environment_antigravity(payload), "commands" => [command],
                 "policy" => [judge(command, judge_cwd)], "payload" => payload, "antigravity" => antigravity_state(hook) }
      plan_output(report, [hook], out, options)
    end

    def antigravity_state(hook)
      { "would_run" => ANTIGRAVITY_RUNNING.include?(hook.status), "status" => hook.status }
    end

    def antigravity_line(report)
      state = report["antigravity"]
      "antigravity would run this hook: #{state['would_run'] ? 'yes' : 'no'} (#{state['status']})"
    end

    def antigravity_timeout(hook)
      value = hook.effective_timeout
      value < 1 ? Model::ANTIGRAVITY_TIMEOUT_DEFAULT : value
    end

    def antigravity_outcome(result, verdict)
      return "timeout" if result[:timed_out]
      return "error" if result[:error] || result[:returncode] != 0

      case verdict[:outcome]
      when "blocked" then "block"
      when "ask" then "ask"
      when "proceed" then "allow"
      else "ok"
      end
    end

    def run_antigravity(hook, event, command, inventory, options, out)
      if hook.status == "prompt" || hook.type == "prompt"
        raise Refused, "ordonnateur does not fire #{hook.id}: prompt hooks call a model; ordonnateur does not fire them"
      end
      if Harnesses::Antigravity.pinned?(hook)
        raise Refused, "ordonnateur does not fire #{hook.id}: #{Harnesses::Antigravity.pinned_reason(hook)}"
      end

      Dir.mktmpdir("ordonnateur-fire") do |tmp|
        out.puts "fire tmpdir: #{tmp} (removed when the fire finishes)" unless options[:json]
        payload, = Payload.build_antigravity(
          event, hook, tmp: tmp, write: true, cwd: options[:cwd] || inventory.root,
          payload_file: options[:payload], sets: options[:sets] || []
        )
        env = Payload.environment_antigravity(payload)
        cwd = File.dirname(hook.source_file)
        verdict = judge(command, cwd)
        report = { "event" => event, "cwd" => cwd, "environment" => env, "commands" => [command],
                   "policy" => [verdict], "payload" => payload, "tmpdir" => tmp, "antigravity" => antigravity_state(hook) }
        guard_run!([hook], [command], [verdict])
        execute_antigravity(report, hook, event, payload, env, cwd, out, options)
      end
      0
    end

    def execute_antigravity(report, hook, event, payload, env, cwd, out, options)
      timeout = antigravity_timeout(hook)
      result = Harnesses::Antigravity.run_hook(hook, JSON.generate(payload), timeout: timeout, env: env, cwd: cwd)
      verdict = Harnesses::Antigravity.interpret(event, result)
      outcome = antigravity_outcome(result, verdict)
      entry = {
        id: hook.id, ran: true, outcome: outcome, antigravity_outcome: verdict[:outcome], exit: result[:returncode],
        ms: result[:elapsed_ms], timeout_s: timeout, raw_stdout: result[:stdout], raw_stderr: result[:stderr],
        stdout: result[:stdout], stderr: result[:stderr], stdout_bytes: result[:stdout].to_s.bytesize,
        error: result[:error]
      }
      decision = verdict[:directive].is_a?(Hash) ? verdict[:directive]["decision"] : nil
      record = {
        "at" => Time.now.utc.iso8601, "source" => "fire", "harness" => "antigravity", "scope" => hook.scope,
        "event" => event, "card" => nil, "session_id" => payload["conversationId"], "total_ms" => result[:elapsed_ms],
        "verdict" => { "decision" => verdict[:blocked] ? "block" : decision, "blocked" => verdict[:blocked] },
        "members" => [Runner.member_record(entry)]
      }
      store(record)
      print_antigravity_run(report, entry, verdict, out, options)
    end

    def print_antigravity_run(report, entry, verdict, out, options)
      shown = {
        "id" => entry[:id], "exit" => entry[:exit], "ms" => entry[:ms], "outcome" => entry[:antigravity_outcome],
        "stdout" => entry[:raw_stdout].to_s[0, CAP], "stderr" => entry[:raw_stderr].to_s[0, CAP], "error" => entry[:error]
      }
      if options[:json]
        out.puts JSON.pretty_generate(
          report.merge("ran" => true, "members" => [shown], "blocked" => verdict[:blocked], "outcome" => verdict[:outcome],
                       "directive" => verdict[:directive], "message" => verdict[:message])
        )
        return
      end
      out.puts antigravity_line(report)
      out.puts "cwd: #{report['cwd']}"
      out.puts "member #{entry[:id]}: exit #{entry[:exit].inspect}, #{entry[:ms]} ms, #{entry[:antigravity_outcome]}"
      out.puts "  error: #{entry[:error]}" if entry[:error]
      out.puts "  stdout: #{entry[:raw_stdout].to_s[0, CAP]}" unless entry[:raw_stdout].to_s.empty?
      out.puts "  stderr: #{entry[:raw_stderr].to_s[0, CAP]}" unless entry[:raw_stderr].to_s.empty?
      out.puts "blocked: #{verdict[:blocked] ? 'yes' : 'no'}#{verdict[:message] ? " (#{verdict[:message]})" : ''}"
      out.puts "directive: #{verdict[:directive] ? JSON.generate(verdict[:directive]) : '(none)'}"
      out.puts "ran for real: side effects of this hook happened"
    end

    def command_text(hook)
      args = hook.args
      args && !args.empty? ? Shellwords.join([hook.command, *args]) : hook.command.to_s
    end

    def judge(command, cwd)
      @ports.policy.judge(tool_name: "Bash", tool_input: { "command" => command }, cwd: cwd)
    end

    def verdict_line(verdict)
      rule = verdict[:rule_id] ? " (#{verdict[:rule_id]})" : ""
      "#{verdict[:verdict]}#{rule} #{verdict[:reason]}".strip
    end

    def plan_output(report, targets, out, options)
      if options[:json]
        out.puts JSON.pretty_generate(report.merge("ran" => false))
        return 0
      end
      targets.each_with_index do |hook, index|
        out.puts "command#{targets.length > 1 ? " #{index + 1}" : ''}: #{report['commands'][index]}"
        out.puts "  id: #{hook.id}"
        out.puts "  policy: #{verdict_line(report['policy'][index])}"
      end
      out.puts "cwd: #{report['cwd']}"
      out.puts "environment: #{report['environment'].map { |k, v| "#{k}=#{v}" }.join(' ')}"
      out.puts hermes_line(report) if report["hermes"]
      out.puts antigravity_line(report) if report["antigravity"]
      out.puts "payload:"
      out.puts JSON.pretty_generate(report["payload"])
      out.puts "not run; add --run to execute it for real"
      0
    end

    def guard_run!(targets, commands, verdicts)
      targets.each do |hook|
        next unless hook.policy_protected

        raise Refused, "ordonnateur does not fire #{hook.id}: #{hook.policy_reason || 'protected by the policy engine'}"
      end
      commands.zip(verdicts).each do |command, verdict|
        case verdict[:verdict]
        when "deny"
          raise Refused, "polispec denies running #{command}: #{verdict[:reason]} (#{verdict[:rule_id]})"
        when "warn"
          raise Refused, "polispec warns on running #{command}: #{verdict[:reason]}; ask the user, then the user runs this command; ordonnateur never proceeds on a warn"
        end
      end
    end

    def execute(report, targets, card_path, event, payload, env, cwd, out, options)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if card_path
        execution = Runner.execute(event, card_path, payload, source: "fire", env: env, cwd: cwd)
        entries = execution.details
        stdout = execution.stdout
        stderr = execution.stderr
        code = execution.exit
        record = execution.record
      else
        hook = targets.first
        timeout = hook.effective_timeout
        result = Member.run(hook.hook, JSON.generate(payload), timeout, env: env, cwd: cwd)
        entry = Member.interpret(event, result).merge(id: hook.id, ran: true, timeout_s: timeout)
        merged = Merge.call(event, [entry])
        entries = [entry]
        stdout = merged[:stdout]
        stderr = merged[:stderr]
        code = merged[:exit]
        record = single_record(hook, event, payload, started, merged, entry)
      end
      store(record)
      print_run(report, entries, stdout, stderr, code, out, options)
    end

    def single_record(hook, event, payload, started, merged, entry)
      stdout = merged[:stdout] || {}
      decision = stdout.dig("hookSpecificOutput", "permissionDecision") || stdout["decision"]
      {
        "at" => Time.now.utc.iso8601, "source" => "fire", "harness" => hook.harness, "scope" => hook.scope,
        "event" => event, "card" => nil, "session_id" => payload["session_id"],
        "total_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
        "verdict" => { "decision" => decision, "blocked" => merged[:exit] == 2 || %w[deny block].include?(decision) },
        "members" => [Runner.member_record(entry)]
      }
    end

    def store(record)
      return unless @settings.on?("run.record")

      @ports.state.append(Recorder.stream_for(record), record)
      Recorder.emit_completed(record, @ports, @settings)
    end

    def print_run(report, entries, stdout, stderr, code, out, options)
      if options[:json]
        shown = entries.map do |entry|
          { "id" => entry[:id], "exit" => entry[:exit], "ms" => entry[:ms], "outcome" => entry[:outcome],
            "stdout" => entry[:raw_stdout].to_s[0, CAP], "stderr" => entry[:raw_stderr].to_s[0, CAP] }
        end
        out.puts JSON.pretty_generate(report.merge("ran" => true, "members" => shown, "verdict" => stdout,
                                                    "verdict_stderr" => stderr, "exit" => code))
        return
      end
      entries.each do |entry|
        out.puts "member #{entry[:id]}: exit #{entry[:exit].inspect}, #{entry[:ms]} ms, #{entry[:outcome]}"
        out.puts "  stdout: #{entry[:raw_stdout].to_s[0, CAP]}" unless entry[:raw_stdout].to_s.empty?
        out.puts "  stderr: #{entry[:raw_stderr].to_s[0, CAP]}" unless entry[:raw_stderr].to_s.empty?
      end
      out.puts "verdict: #{stdout ? JSON.generate(stdout) : '(no output)'}"
      out.puts "verdict stderr: #{stderr}" if stderr && !stderr.empty?
      out.puts "verdict exit: #{code}"
      out.puts "ran for real: side effects of these hooks happened"
    end
  end
end
