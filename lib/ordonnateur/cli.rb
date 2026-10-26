#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "optparse"

require_relative "model"
require_relative "inventory"
require_relative "card"
require_relative "takeover"
require_relative "hermes_order"
require_relative "runner"
require_relative "recorder"
require_relative "lint"
require_relative "timings"
require_relative "fire"
require_relative "watch"

module Ordonnateur
  module Cli
    ROOT = File.expand_path("../..", __dir__)

    USAGE = {
      "list" => "ordonnateur list [--harness H] [--event E] [--project DIR] [--json]",
      "card" => "ordonnateur card [--scope user|local] [--project DIR] [--json]",
      "order" => "ordonnateur order <Event> <hook>... [--harness claude-code|hermes] [--scope user|local] [--project DIR] [--stop-on-block|--no-stop-on-block] [--apply]",
      "move" => "ordonnateur move <Event> <hook> (--first|--last|--before <hook>|--after <hook>) [--harness claude-code|hermes] [--scope user|local] [--project DIR] [--apply]",
      "release" => "ordonnateur release (<Event>|--all) [--harness claude-code|hermes] [--scope user|local] [--project DIR] [--apply]",
      "unguard" => "ordonnateur unguard <hook> [--scope user|local] [--project DIR] [--apply]",
      "guard" => "ordonnateur guard <hook> [--scope user|local] [--project DIR] [--apply]",
      "lint" => "ordonnateur lint [--harness H] [--project DIR] [--json]",
      "timings" => "ordonnateur timings [--event E] [--months N] [--json]",
      "fire" => "ordonnateur fire (<hook>|--event <Event>) [--scope user|local] [--payload FILE] [--set key=json]... [--cwd DIR] [--run] [--json] [--project DIR]",
      "watch" => "ordonnateur watch [--quiet] [--json] [--project DIR]",
      "run" => "ordonnateur run claude-code <Event> --card <path>",
      "record" => "ordonnateur record",
      "web" => "ordonnateur web [--bind ADDR] [--port N] [--public-origin URL] [--expose] [--open] [--read-only] [--json]\n    ordonnateur web url [--json]",
      "version" => "ordonnateur version"
    }.freeze

    module_function

    def run(argv, out: $stdout, err: $stderr)
      command = argv.shift
      case command
      when nil, "--help", "-h", "help"
        out.puts help_text
        0
      when *USAGE.keys then dispatch(command, argv, out, err)
      else
        err.puts "ordonnateur: unknown command #{command.inspect}; see `ordonnateur --help`"
        2
      end
    rescue Error => e
      err.puts "ordonnateur: #{e.message}"
      e.exit_code
    end

    def dispatch(command, argv, out, err)
      if argv.include?("--help") || argv.include?("-h")
        out.puts USAGE.fetch(command)
        return 0
      end
      send("cmd_#{command}", argv, out, err)
    end

    def help_text
      (["usage:"] + USAGE.values.map { |line| "  #{line}" }).join("\n")
    end

    def parse(argv, usage)
      options = {}
      parser = OptionParser.new
      parser.banner = usage
      yield parser, options
      parser.parse!(argv)
      options
    rescue OptionParser::ParseError => e
      raise Usage, "#{e.message}; usage: #{usage}"
    end

    def ports
      @ports ||= Rplugin::Ports.for("ordonnateur", root: ROOT)
    end

    def full_inventory(harness:, project:)
      Inventory.load_full(harness: harness, project: project, policy: ports.policy)
    end

    def scope_option(parser, opts)
      opts[:scope] = "user"
      parser.on("--scope S") { |v| opts[:scope] = v }
      parser.on("--project DIR") { |v| opts[:project] = v }
      parser.on("--apply") { opts[:apply] = true }
    end

    NO_CARDS = "Hermes has no cards; ordonnateur reorders its hooks in place".freeze

    def takeover_for(options)
      Takeover.new(scope: options[:scope], project: options[:project], ports: ports)
    end

    def harness_option(parser, opts)
      parser.on("--harness H") { |v| opts[:harness] = v }
    end

    def hermes_ref?(ref)
      ref.to_s.start_with?("#{Model.prefix('hermes')}:")
    end

    def resolve_harness(options, refs)
      harness = options[:harness]
      raise Usage, "harness must be claude-code or hermes" if harness && !%w[claude-code hermes].include?(harness)

      hermes = refs.compact.select { |ref| hermes_ref?(ref) }
      if !hermes.empty? && hermes.length != refs.compact.length
        raise Refused, "refused:\n  hooks of different harnesses cannot be ordered together"
      end
      if harness == "claude-code" && !hermes.empty?
        raise Refused, "refused:\n  #{hermes.first} belongs to Hermes, not claude-code"
      end
      return "hermes" if harness == "hermes" || !hermes.empty?

      "claude-code"
    end

    def hermes_planner(options, out)
      raise Usage, "Hermes keeps a single scope, user" unless options[:scope] == "user"
      raise Usage, "--stop-on-block does not apply to Hermes" unless options[:stop].nil?

      out.puts "note: --project is ignored for Hermes" if options[:project]
      HermesOrder.new(ports: ports)
    end

    def refuse_hermes_card!(refs)
      return unless refs.compact.any? { |ref| hermes_ref?(ref) }

      raise Refused, "refused:\n  #{NO_CARDS}"
    end

    def run_plan(takeover, plan, options, out)
      out.puts takeover.render(plan)
      if options[:apply]
        out.puts(takeover.apply(plan) ? "applied" : "no changes to apply")
      else
        out.puts(takeover.changed?(plan) ? "not applied; add --apply to write these changes" : "no changes")
      end
      0
    end

    def settings
      @settings ||= Rplugin::Settings.for(ROOT)
    end

    def command_index(hooks)
      hooks.to_h { |hook| [hook.id, hook.command.to_s] }
    end

    def cmd_lint(argv, out, _err)
      options = parse(argv, USAGE["lint"]) do |parser, opts|
        parser.on("--harness H") { |v| opts[:harness] = v }
        parser.on("--project DIR") { |v| opts[:project] = v }
        parser.on("--json") { opts[:json] = true }
      end
      harness = options[:harness] || "all"
      inventory = full_inventory(harness: harness, project: options[:project])
      slow = settings.get("lint.slow_ms")
      rows = Timings.rows(Timings.records(ports, 2), slow_ms: slow)
      findings = Lint.run(inventory, rows: rows, slow_ms: slow, harness: harness)
      Lint.emit_completed(findings, ports, settings)
      if options[:json]
        out.puts JSON.pretty_generate({ "findings" => findings })
      else
        inventory.notes.each { |note| out.puts "note: #{note}" }
        findings.each do |item|
          out.puts "#{item['severity'].upcase.ljust(5)} #{item['code']} #{item['hook']}: #{item['message']}#{item['fix'] ? " (fix: #{item['fix']})" : ''}"
        end
        out.puts "#{findings.length} finding(s)"
      end
      Lint.failing?(findings) ? 1 : 0
    end

    def cmd_timings(argv, out, _err)
      options = parse(argv, USAGE["timings"]) do |parser, opts|
        parser.on("--event E") { |v| opts[:event] = v }
        parser.on("--months N", Integer) { |v| opts[:months] = v }
        parser.on("--json") { opts[:json] = true }
      end
      months = options[:months] || 2
      raise Usage, "--months must be at least 1" if months < 1

      rows = Timings.rows(Timings.records(ports, months), event: options[:event], slow_ms: settings.get("lint.slow_ms"))
      commands = command_index(full_inventory(harness: "all", project: nil).hooks)
      rows.each { |row| row["command"] = commands[row["id"]].to_s[0, 60] }
      if options[:json]
        out.puts JSON.pretty_generate({ "timings" => rows })
      else
        rows.each do |row|
          flags = [row["slow"] ? "slow" : nil, row["near_timeout"] ? "near-timeout" : nil].compact.join(",")
          out.puts [row["harness"], row["event"], row["id"], row["runs"], row["p50"], row["p95"], row["max"],
                    row["failures"], row["command"], flags].join("  ")
        end
        out.puts "no recorded runs" if rows.empty?
      end
      0
    end

    def cmd_watch(argv, out, _err)
      options = parse(argv, USAGE["watch"]) do |parser, opts|
        parser.on("--quiet") { opts[:quiet] = true }
        parser.on("--json") { opts[:json] = true }
        parser.on("--project DIR") { |v| opts[:project] = v }
      end
      Watch.new(ports: ports, settings: settings).call(options, out)
    end

    def cmd_fire(argv, out, _err)
      options = parse(argv, USAGE["fire"]) do |parser, opts|
        opts[:sets] = []
        parser.on("--event E") { |v| opts[:event] = v }
        parser.on("--scope S") { |v| opts[:scope] = v }
        parser.on("--payload FILE") { |v| opts[:payload] = v }
        parser.on("--set KV") { |v| opts[:sets] << v }
        parser.on("--cwd DIR") { |v| opts[:cwd] = v }
        parser.on("--project DIR") { |v| opts[:project] = v }
        parser.on("--run") { opts[:run] = true }
        parser.on("--json") { opts[:json] = true }
      end
      options[:ref] = argv.first
      raise Usage, "usage: #{USAGE['fire']}" if options[:ref].nil? == options[:event].nil?

      Fire.new(ports: ports, settings: settings).call(options, out)
    end

    def cmd_run(argv, _out, _err)
      Runner.main(argv)
    end

    def cmd_record(_argv, _out, _err)
      settings = Rplugin::Settings.for(ROOT)
      return 0 unless settings.on?("run.record")

      record = JSON.parse($stdin.read)
      Recorder.store(record, ports, settings)
      0
    rescue JSON::ParserError
      1
    end

    def cmd_web(argv, out, err)
      require_relative "web"
      Web.run(argv, out: out, err: err, ports: ports, settings: settings)
    end

    def cmd_version(_argv, out, _err)
      out.puts File.read(File.join(ROOT, "VERSION")).strip
      0
    end

    def cmd_card(argv, out, _err)
      options = parse(argv, USAGE["card"]) do |parser, opts|
        scope_option(parser, opts)
        parser.on("--json") { opts[:json] = true }
      end
      raise Usage, "scope must be user or local" unless %w[user local].include?(options[:scope])

      root = Harnesses::ClaudeCode.project_root(options[:project])
      path = Harnesses::ClaudeCode.card_path(options[:scope], root)
      card = begin
        Card.load_if_present(path)
      rescue Card::Invalid => e
        raise Refused, e.message
      end
      if options[:json]
        out.puts JSON.pretty_generate({ "path" => path, "card" => card })
      elsif card.nil?
        out.puts "no card at #{path}"
      else
        out.puts "card #{path}"
        out.puts "settings_file #{card['settings_file']}"
        out.puts "unguarded #{card['unguarded'].length}"
        card["events"].each do |event, entry|
          out.puts "#{event} (stop_on_block: #{entry['stop_on_block']})"
          entry["members"].each_with_index do |member, index|
            mark = Card.digest_ok?(member) ? "" : "  DIGEST MISMATCH"
            out.puts "  #{index + 1}. #{member['id']}  #{member['hook']['command'].to_s[0, 60]}#{mark}"
          end
        end
      end
      0
    end

    def cmd_order(argv, out, _err)
      options = parse(argv, USAGE["order"]) do |parser, opts|
        scope_option(parser, opts)
        harness_option(parser, opts)
        parser.on("--[no-]stop-on-block") { |v| opts[:stop] = v }
      end
      event, *refs = argv
      raise Usage, "usage: #{USAGE['order']}" if event.nil?

      if resolve_harness(options, refs) == "hermes"
        planner = hermes_planner(options, out)
        return run_plan(planner, planner.plan_order(event, refs), options, out)
      end
      takeover = takeover_for(options)
      run_plan(takeover, takeover.plan_order(event, refs, stop_on_block: options[:stop]), options, out)
    end

    def cmd_move(argv, out, _err)
      options = parse(argv, USAGE["move"]) do |parser, opts|
        scope_option(parser, opts)
        harness_option(parser, opts)
        parser.on("--first") { opts[:mode] = :first }
        parser.on("--last") { opts[:mode] = :last }
        parser.on("--before H") { |v| opts[:mode] = :before; opts[:other] = v }
        parser.on("--after H") { |v| opts[:mode] = :after; opts[:other] = v }
      end
      event, ref = argv
      raise Usage, "usage: #{USAGE['move']}" if event.nil? || ref.nil? || options[:mode].nil?

      if resolve_harness(options, [ref, options[:other]]) == "hermes"
        planner = hermes_planner(options, out)
        return run_plan(planner, planner.plan_move(event, ref, options[:mode], options[:other]), options, out)
      end
      takeover = takeover_for(options)
      run_plan(takeover, takeover.plan_move(event, ref, options[:mode], options[:other]), options, out)
    end

    def cmd_release(argv, out, _err)
      options = parse(argv, USAGE["release"]) do |parser, opts|
        scope_option(parser, opts)
        harness_option(parser, opts)
        parser.on("--all") { opts[:all] = true }
      end
      event = argv.first
      raise Usage, "usage: #{USAGE['release']}" if (event.nil? && !options[:all]) || (event && options[:all])

      harness = options[:harness]
      raise Usage, "harness must be claude-code or hermes" if harness && !%w[claude-code hermes].include?(harness)
      raise Refused, "refused:\n  #{NO_CARDS}" if harness == "hermes"

      takeover = takeover_for(options)
      run_plan(takeover, takeover.plan_release(options[:all] ? nil : event), options, out)
    end

    def cmd_unguard(argv, out, _err)
      options = parse(argv, USAGE["unguard"]) { |parser, opts| scope_option(parser, opts) }
      raise Usage, "usage: #{USAGE['unguard']}" if argv.length != 1

      refuse_hermes_card!(argv)
      takeover = takeover_for(options)
      run_plan(takeover, takeover.plan_unguard(argv.first), options, out)
    end

    def cmd_guard(argv, out, _err)
      options = parse(argv, USAGE["guard"]) { |parser, opts| scope_option(parser, opts) }
      raise Usage, "usage: #{USAGE['guard']}" if argv.length != 1

      refuse_hermes_card!(argv)
      takeover = takeover_for(options)
      run_plan(takeover, takeover.plan_guard(argv.first), options, out)
    end

    def cmd_list(argv, out, _err)
      options = parse(argv, USAGE["list"]) do |parser, opts|
        parser.on("--harness H") { |v| opts[:harness] = v }
        parser.on("--event E") { |v| opts[:event] = v }
        parser.on("--project DIR") { |v| opts[:project] = v }
        parser.on("--json") { opts[:json] = true }
      end
      result = full_inventory(harness: options[:harness] || "all", project: options[:project])
      hooks = result.hooks
      hooks = hooks.select { |hook| hook.event == options[:event] } if options[:event]
      if options[:json]
        out.puts JSON.pretty_generate({ "hooks" => hooks.map(&:to_h), "notes" => result.notes })
      else
        print_list(hooks, out)
      end
      0
    end

    def print_list(hooks, out)
      rows = hooks.map do |hook|
        [hook.id, hook.matcher.to_s, hook.status.to_s, hook.timeout.to_s, hook.command.to_s[0, 70]]
      end
      widths = (0..3).map { |i| rows.map { |row| row[i].length }.max.to_i }
      last = nil
      hooks.each_with_index do |hook, index|
        key = [hook.harness, hook.event]
        if key != last
          out.puts "#{hook.harness} #{hook.event}"
          last = key
        end
        row = rows[index]
        cells = (0..3).map { |i| row[i].ljust(widths[i]) }
        out.puts "  #{cells.join('  ')}  #{row[4]}"
      end
    end
  end
end
