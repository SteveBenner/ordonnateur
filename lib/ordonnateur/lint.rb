#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "shellwords"

require_relative "model"
require_relative "card"
require_relative "inventory"

module Ordonnateur
  module Lint
    BUILTINS = %w(true false exit echo test [ cd : printf).freeze
    FAILING = %w[error warn].freeze
    ANTIGRAVITY_BUILTINS = %w[. exec eval export set unset read trap wait].freeze
    ANTIGRAVITY_INERT = %w[file-skipped ignored-event].freeze
    ANTIGRAVITY_RUNNING = %w[active member prompt].freeze
    ANTIGRAVITY_TOOL_FIXES = {
      "Bash" => "run_command", "Read" => "view_file", "Write" => "write_to_file", "Edit" => "replace_file_content",
      "MultiEdit" => "multi_replace_file_content", "Glob" => "find_by_name", "Grep" => "grep_search", "LS" => "list_dir",
      "WebFetch" => "read_url_content", "WebSearch" => "search_web", "Task" => "invoke_subagent"
    }.freeze

    module_function

    def finding(code, severity, hook, message, fix = nil, harness: nil)
      {
        "code" => code, "severity" => severity, "harness" => harness || (hook.respond_to?(:harness) ? hook.harness : nil),
        "hook" => hook.respond_to?(:id) ? hook.id : hook, "message" => message, "fix" => fix
      }
    end

    def active(hooks)
      hooks.reject { |hook| hook.plugin && !hook.plugin_enabled }
    end

    def run(inventory, rows: [], slow_ms: 2000, harness: "all")
      hooks = active(inventory.hooks)
      found = []
      found.concat(dead(inventory, hooks))
      found.concat(duplicates(hooks))
      found.concat(matchers_and_events(hooks))
      found.concat(escaped(inventory))
      found.concat(twins(inventory))
      found.concat(cards(inventory, hooks))
      found.concat(managed_only(inventory))
      found.concat(protected_members(inventory))
      found.concat(plugin_paths(inventory))
      found.concat(session_end(hooks))
      found.concat(timing(rows, slow_ms))
      found.concat(codex(inventory))
      found.concat(hermes(inventory))
      found.concat(antigravity(inventory))
      found = found.select { |item| harness == "all" || item["harness"].nil? || item["harness"] == harness }
      found.sort_by { |item| [%w[error warn info].index(item["severity"]), item["code"], item["hook"].to_s] }
    end

    def emit_completed(findings, ports, settings)
      return unless settings.on?("events.runs")

      count = ->(level) { findings.count { |item| item["severity"] == level } }
      codes = findings.each_with_object(Hash.new(0)) { |item, memo| memo[item["code"]] += 1 }
      ports.events.emit(
        "ordonnateur.lint.completed",
        { "errors" => count.call("error"), "warnings" => count.call("warn"), "infos" => count.call("info"), "codes" => codes }
      )
    end

    def failing?(findings)
      findings.any? { |item| FAILING.include?(item["severity"]) }
    end

    def expand(word, hook, root)
      text = word.dup
      text = text.sub(/\A~(?=\/|\z)/, Dir.home)
      text = text.gsub(/\$\{HOME\}|\$HOME(?![A-Za-z0-9_])/, Dir.home)
      text = text.gsub(/\$\{CLAUDE_PROJECT_DIR\}|\$CLAUDE_PROJECT_DIR(?![A-Za-z0-9_])/, root)
      if hook.plugin_root
        text = text.gsub(/\$\{CLAUDE_PLUGIN_ROOT\}|\$\{PLUGIN_ROOT\}/, hook.plugin_root)
      end
      text
    end

    def program_of(hook)
      return hook.command if hook.args && !hook.args.empty?

      words = Shellwords.split(hook.command)
      words.shift while words.first&.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/)
      words.first
    rescue ArgumentError
      nil
    end

    def executable_file?(path)
      File.file?(path) && File.executable?(path)
    end

    def dead(inventory, hooks)
      hooks.filter_map do |hook|
        next unless hook.command && (hook.type.nil? || hook.type == "command")
        next if hook.status == "disabled"
        next if hook.harness == "antigravity" && ANTIGRAVITY_INERT.include?(hook.status)

        word = hook.harness == "hermes" ? hermes_program(hook) : program_of(hook)
        next if word.nil? || word.empty?

        if hook.harness == "antigravity"
          next if word.include?("$")

          word = word.sub(/\A~(?=\/|\z)/, Dir.home)
          word = File.expand_path(word, File.dirname(hook.source_file)) if word.include?("/")
        elsif hook.harness != "hermes"
          word = expand(word, hook, inventory.root)
        end
        next if word.include?("$")

        builtins = hook.harness == "antigravity" ? BUILTINS + ANTIGRAVITY_BUILTINS : BUILTINS
        ok =
          if word.include?("/") then executable_file?(word)
          elsif builtins.include?(word) then true
          else ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| executable_file?(File.join(dir, word)) }
          end
        next if ok

        finding("ORD-DEAD", "warn", hook, "program #{word} does not exist or is not executable",
                "fix the path or remove the hook")
      end
    end

    def hermes_program(hook)
      words = Shellwords.split(Harnesses::Hermes.expand_user(hook.command.to_s.strip))
      words.first
    rescue ArgumentError
      nil
    end

    def duplicates(hooks)
      pool = hooks.select do |hook|
        hook.harness != "antigravity" && hook.command && !hook.status.to_s.start_with?("member#") && hook.status != "dispatcher"
      end
      found = pool.group_by { |hook| [hook.harness, hook.event, hook.command] }.filter_map do |(harness, event, command), list|
        pairs = []
        list.combination(2) do |a, b|
          next if a.source_file == b.source_file
          next unless Matcher.overlap?(a.matcher, b.matcher)

          pairs << [a, b]
        end
        next if pairs.empty?

        plugin_pair = pairs.any? { |a, b| a.plugin || b.plugin }
        severity = harness == "codex" || plugin_pair ? "warn" : "info"
        places = pairs.flatten.map { |hook| hook.plugin ? "plugin #{hook.plugin}" : hook.source_file }.uniq
        message = "#{command[0, 60]} on #{event} is defined in #{places.join(', ')}"
        message += "; Claude Code runs identical settings-file handlers once" if severity == "info"
        finding("ORD-DUP", severity, pairs.first.first.id, message, "keep one definition", harness: harness)
      end
      found + antigravity_duplicates(hooks)
    end

    def antigravity_duplicates(hooks)
      pool = hooks.select do |hook|
        hook.harness == "antigravity" && hook.command && ANTIGRAVITY_RUNNING.include?(hook.status)
      end
      pool.group_by { |hook| [hook.source_file, hook.event, hook.command] }.filter_map do |(file, event, command), list|
        pairs = []
        list.combination(2) do |a, b|
          next unless Matcher.overlap?(a.matcher, b.matcher)

          pairs << [a, b]
        end
        next if pairs.empty?

        message = "#{command[0, 60]} on #{event} is defined #{pairs.flatten.uniq.length} times in #{file}; Antigravity runs each"
        finding("ORD-DUP", "warn", pairs.first.first.id, message, "keep one definition", harness: "antigravity")
      end
    end

    def matchers_and_events(hooks)
      hooks.flat_map do |hook|
        next [] if hook.harness == "antigravity"

        found = []
        if hook.harness == "hermes"
          unless Matcher.valid?(hook.matcher)
            found << finding("ORD-MATCHER", "warn", hook, "matcher #{hook.matcher.inspect} does not compile", "fix the regular expression")
          end
          known = Model.events_for("hermes").include?(hook.event) || Model::HERMES_PYTHON_ONLY_EVENTS.include?(hook.event)
          found << finding("ORD-EVENT", "warn", hook, "#{hook.event} is not a known hermes event, so the hook never fires", "check the event name") unless known
          next found
        end
        unless Matcher.valid?(hook.matcher)
          found << finding("ORD-MATCHER", "warn", hook, "matcher #{hook.matcher.inspect} does not compile", "fix the regular expression")
        end
        if hook.harness == "claude-code" && Model::NO_MATCHER_EVENTS.include?(hook.event) &&
           !Matcher.all?(hook.matcher) && !hook.status.to_s.start_with?("member#")
          found << finding("ORD-MATCHER", "info", hook, "#{hook.event} has no matcher support; Claude Code ignores the matcher", "remove the matcher")
        end
        unless Model.events_for(hook.harness).include?(hook.event)
          severity = hook.harness == "claude-code" ? "warn" : "info"
          found << finding("ORD-EVENT", severity, hook, "#{hook.event} is not a known #{hook.harness} event, so the hook never fires",
                           "check the event name")
        end
        found
      end
    end

    def escaped(inventory)
      inventory.cards.flat_map do |scope, entry|
        card = entry[:card]
        next [] unless card

        inventory.hooks.select do |hook|
          hook.harness == "claude-code" && hook.scope == scope && hook.plugin.nil? && hook.absorbable &&
            Card.members(card, hook.event).any?
        end.map do |hook|
          finding("ORD-ESCAPED", "warn", hook, "runs outside the #{hook.event} sequence of the #{scope} card",
                  "ordonnateur order #{hook.event} ... including it")
        end
      end
    end

    def twins(inventory)
      plain = inventory.hooks.select { |hook| hook.harness == "claude-code" && hook.plugin.nil? && !hook.status.to_s.start_with?("member#") }
      inventory.members.filter_map do |member|
        card = inventory.cards[member.scope][:card]
        key = Canonical.json(member.hook)
        other = plain.find do |hook|
          hook.event == member.event && hook.source_file != card["settings_file"] && Canonical.json(hook.hook) == key
        end
        next unless other

        finding("ORD-TWIN", "warn", member, "also defined in #{other.source_file}, so it now runs twice",
                "remove one definition")
      end
    end

    def cards(inventory, hooks)
      found = []
      inventory.cards.each do |scope, entry|
        if entry[:error]
          found << finding("ORD-CARD", "error", entry[:path], entry[:error], "repair or remove the card", harness: "claude-code")
          next
        end
        card = entry[:card]
        next unless card

        card["events"].each do |event, ev|
          unless hooks.any? { |hook| hook.dispatcher? && hook.scope == scope && hook.event == event }
            found << finding("ORD-CARD", "error", entry[:path], "#{event} has members but no dispatcher entry in #{card['settings_file']}",
                             "ordonnateur order #{event} ... --scope #{scope} --apply", harness: "claude-code")
          end
          ev["members"].each do |member|
            next if Card.digest_ok?(member)

            found << finding("ORD-CARD-DIGEST", "error", member["id"], "digest does not match matcher and hook; the dispatcher will not run it",
                             "ordonnateur release #{event} --scope #{scope} --apply", harness: "claude-code")
          end
        end
      end
      hooks.select(&:dispatcher?).each do |hook|
        path = Model.dispatcher_card_path(hook.command)
        problem =
          begin
            card = Card.read(path.to_s)
            members = Card.members(card, hook.event)
            members.empty? ? "card #{path} has no #{hook.event} entry" : nil
          rescue Card::Invalid => e
            e.message
          end
        next unless problem

        found << finding("ORD-CARD", "error", hook, "dispatcher points at a card problem: #{problem}", "remove the dispatcher or repair the card")
      end
      found
    end

    def managed_only(inventory)
      return [] unless inventory.claude && Harnesses::ClaudeCode.managed_only?(inventory.claude[:sources])

      carded = inventory.cards.values.any? { |entry| entry[:card] }
      if carded
        [finding("ORD-MANAGED-ONLY", "error", "managed-settings", "allowManagedHooksOnly is true, so Claude Code ignores the dispatcher and every member",
                 "release the cards or lift allowManagedHooksOnly", harness: "claude-code")]
      else
        count = inventory.hooks.count { |hook| hook.harness == "claude-code" && hook.scope != "managed" }
        [finding("ORD-MANAGED-ONLY", "info", "managed-settings", "allowManagedHooksOnly is true; #{count} non-managed hook(s) are inactive",
                 nil, harness: "claude-code")]
      end
    end

    def protected_members(inventory)
      inventory.members.select(&:policy_protected).map do |member|
        finding("ORD-PROTECTED", "error", member, "is protected by the policy engine (#{member.policy_reason}) and must not be sequenced",
                "ordonnateur guard #{member.short} --apply")
      end
    end

    def plugin_paths(inventory)
      return [] unless inventory.claude

      cache = Harnesses::ClaudeCode.plugin_cache_dir
      pattern = %r{#{Regexp.escape(cache)}/([^/\s"']+)/([^/\s"']+)/([^/\s"'$]+)}
      inventory.hooks.select { |hook| hook.harness == "claude-code" && hook.plugin && hook.command }.flat_map do |hook|
        hook.command.scan(pattern).filter_map do |marketplace, name, version|
          next unless hook.plugin == "#{name}@#{marketplace}"
          next if File.join(cache, marketplace, name, version) == hook.plugin_root

          finding("ORD-PLUGIN-PATH", "warn", hook, "points into version #{version} of #{hook.plugin}, which is not the active install",
                  "use ${CLAUDE_PLUGIN_ROOT}")
        end
      end
    end

    def session_end(hooks)
      list = hooks.select { |hook| hook.harness == "claude-code" && hook.event == "SessionEnd" }
      return [] unless list.length > 1

      [finding("ORD-SESSIONEND", "info", "SessionEnd", "#{list.length} SessionEnd hooks share a 1.5-second budget", nil, harness: "claude-code")]
    end

    def timing(rows, slow_ms)
      rows.flat_map do |row|
        found = []
        if row["slow"]
          found << finding("ORD-SLOW", "warn", row["id"], "p95 #{row['p95']} ms over #{row['runs']} runs exceeds #{slow_ms} ms",
                           "make the hook faster", harness: row["harness"])
        end
        if row["near_timeout"]
          found << finding("ORD-NEARTIMEOUT", "warn", row["id"], "a run reached #{row['max']} ms of a #{row['timeout_s']} s timeout",
                           "raise the timeout or speed the hook up", harness: row["harness"])
        end
        found
      end
    end

    def codex(inventory)
      return [] unless inventory.codex

      found = inventory.hooks.select { |hook| hook.harness == "codex" }.filter_map do |hook|
        case hook.status
        when "untrusted"
          finding("ORD-CODEX-UNTRUSTED", "warn", hook, "has no trust record, so Codex does not run it until it is trusted in /hooks",
                  "trust it in Codex's /hooks view")
        when "disabled"
          finding("ORD-CODEX-DISABLED", "info", hook, "is disabled in hooks.state")
        end
      end
      inventory.codex[:layers].each do |layer|
        layer[:stale].each do |key|
          found << finding("ORD-CODEX-STALE-TRUST", "info", key, "hooks.state key names no current hook", "remove the entry", harness: "codex")
        end
        if layer[:json_count].positive? && layer[:toml_count].positive?
          found << finding("ORD-CODEX-BOTH", "warn", layer[:dir], "#{layer[:scope]} layer defines hooks in both hooks.json and config.toml",
                           "keep a single representation", harness: "codex")
        end
        layer[:parsed][:warnings].each do |warning|
          found << finding("ORD-CODEX-TOML", "info", "#{layer[:toml_path]}:#{warning[:line]}", warning[:message], nil, harness: "codex")
        end
      end
      found
    end

    def unquoted_dollar?(command)
      single = false
      double = false
      escaped = false
      command.each_char do |char|
        if escaped
          escaped = false
        elsif char == "\\" && !single
          escaped = true
        elsif char == "'" && !double
          single = !single
        elsif char == '"' && !single
          double = !double
        elsif char == "$" && !single
          return true
        end
      end
      false
    end

    def hermes_entry_findings(hook)
      raw = hook.hook
      found = []
      matcher = hook.matcher
      if !Matcher.all?(matcher) && !Model::HERMES_TOOL_EVENTS.include?(hook.event)
        found << finding("ORD-HERMES-MATCHER-IGNORED", "warn", hook,
                         "#{hook.event} is not a tool event, so Hermes ignores the matcher #{matcher.inspect}", "remove the matcher")
      end
      closed = raw.key?("fail_closed") ? raw["fail_closed"] : raw["failClosed"]
      if closed == true && !Model::HERMES_BLOCKING_EVENTS.include?(hook.event)
        found << finding("ORD-HERMES-FAILCLOSED-IGNORED", "warn", hook,
                         "#{hook.event} cannot block, so Hermes ignores fail_closed", "remove fail_closed")
      end
      if raw.key?("timeout")
        value = raw["timeout"]
        unless value.is_a?(Integer) && value >= 1 && value <= 300
          found << finding("ORD-HERMES-TIMEOUT", "warn", hook,
                           "timeout #{value.inspect} is not an integer from 1 to 300; Hermes resets or clamps it", "use whole seconds from 1 to 300")
        end
      end
      if hook.command && unquoted_dollar?(hook.command)
        found << finding("ORD-HERMES-ENV", "warn", hook,
                         "the command contains $; Hermes runs no shell and expands only a leading ~", "use an absolute path or a wrapper script")
      end
      found
    end

    def hermes(inventory)
      state = inventory.hermes
      return [] unless state

      hooks = inventory.hooks.select { |hook| hook.harness == "hermes" }
      found = hooks.flat_map do |hook|
        items = []
        if hook.status == "not-allowlisted"
          message =
            if Harnesses::Hermes.pinned?(hook)
              "is not allowlisted, so Hermes does not run it and the guard does not run"
            else
              "is not allowlisted, so Hermes does not run it"
            end
          items << finding("ORD-HERMES-UNALLOWLISTED", "warn", hook, message, "approve it in Hermes (hermes hooks)")
        end
        items.concat(hermes_entry_findings(hook))
        if Model::HERMES_PYTHON_ONLY_EVENTS.include?(hook.event)
          items << finding("ORD-HERMES-EVENT", "warn", hook, "#{hook.event} is Python-plugin-only, so Hermes refuses a shell hook on it",
                           "remove the hook")
        end
        items
      end
      hooks.group_by { |hook| [hook.event, hook.matcher, hook.command.to_s.strip] }.each_value do |list|
        next unless list.length > 1

        found << finding("ORD-HERMES-DUP", "warn", list.last, "is listed #{list.length} times on #{list.first.event}; Hermes registers one",
                         "remove the duplicate entry")
      end
      state[:stale].each do |event, command|
        found << finding("ORD-HERMES-STALE-CONSENT", "info", "#{event} #{command}",
                         "the allowlist approves a command that no configured hook uses", "remove the entry in Hermes", harness: "hermes")
      end
      state[:bad_entries].each do |event, index, reason|
        found << finding("ORD-HERMES-BADENTRY", "warn", "hooks.#{event}[#{index}]",
                         "Hermes skips this entry: #{reason}", "fix the entry", harness: "hermes")
      end
      if state[:allowlist_readable] == false
        found << finding("ORD-HERMES-ALLOWLIST", "warn", state[:allowlist_path],
                         "the allowlist exists but is unreadable or malformed, so Hermes treats every hook as not approved",
                         "repair it in Hermes", harness: "hermes")
      end
      found
    end

    def antigravity(inventory)
      state = inventory.antigravity
      return [] unless state

      files = state[:files].reject { |file| file[:plugin] && !file[:enabled] }
      hooks = inventory.hooks.select do |hook|
        hook.harness == "antigravity" && !(hook.plugin && !hook.plugin_enabled)
      end
      found = antigravity_files(files)
      found.concat(antigravity_hooks(hooks))
      found.concat(antigravity_groups(files))
      found.concat(antigravity_order(hooks))
      found.concat(antigravity_ledgers(files, hooks, state[:ledgers]))
      found
    end

    def antigravity_finding(code, severity, subject, message, fix = nil)
      finding(code, severity, subject, message, fix, harness: "antigravity")
    end

    def antigravity_files(files)
      files.flat_map do |file|
        path = file[:path]
        unless file[:json]
          next [antigravity_finding("ORD-AG-NOTJSON", "error", path, "Antigravity cannot read this file: #{file[:error]}", "fix the file")]
        end

        found = []
        if file[:error]
          found << antigravity_finding("ORD-AG-SKIPPED", "error", path, "Antigravity skips this whole file: #{file[:error]}", "fix the file")
        end
        file[:duplicates].each do |name|
          found << antigravity_finding("ORD-AG-DUPNAME", "warn", "#{path} #{name}",
                                       "the hook name #{name.inspect} appears more than once in #{path}; the last one wins",
                                       "rename or merge the duplicates")
        end
        if file[:data].is_a?(Hash) && file[:error].nil?
          file[:data].each do |name, spec|
            next unless spec.is_a?(Hash) && spec["enabled"] == false

            found << antigravity_finding("ORD-AG-DISABLED", "info", "#{path} #{name}",
                                         "hook #{name.inspect} is disabled (enabled is false), so none of its handlers run")
          end
        end
        found
      end
    end

    def antigravity_alternatives(matcher)
      matcher.split("|").map { |item| item.strip.sub(/\A[\^(]+/, "").sub(/[)$]+\z/, "") }
    end

    def antigravity_tool_names(hook)
      names = antigravity_alternatives(hook.matcher) & Model::ANTIGRAVITY_CLAUDE_TOOLS
      return nil if names.empty?

      fixes = names.filter_map { |name| (tool = ANTIGRAVITY_TOOL_FIXES[name]) && "#{tool} for #{name}" }
      fix = fixes.empty? ? "use Antigravity tool names" : "use #{fixes.join(', ')}"
      [names, fix]
    end

    def antigravity_hooks(hooks)
      hooks.flat_map do |hook|
        next [] if hook.status == "file-skipped"

        if hook.status == "ignored-event"
          next [antigravity_finding("ORD-AG-EVENT", "warn", hook, "#{hook.event} is not an Antigravity event, so Antigravity ignores the hook",
                                    "check the event name")]
        end
        next [] if hook.command.nil? && hook.type != "prompt"

        found = []
        if hook.status == "prompt"
          found << antigravity_finding("ORD-AG-PROMPT", "info", hook, "is a prompt hook; ordonnateur cannot fire a prompt hook")
        end
        if Model::ANTIGRAVITY_TOOL_EVENTS.include?(hook.event) && hook.matcher.is_a?(String)
          if Matcher.valid?(hook.matcher)
            names, fix = antigravity_tool_names(hook)
            if names
              found << antigravity_finding("ORD-AG-CLAUDE-TOOL", "warn", hook,
                                           "matcher #{hook.matcher.inspect} names Claude Code #{names.length == 1 ? 'tool' : 'tools'} #{names.join(', ')}, which never match in Antigravity",
                                           fix)
            end
          else
            found << antigravity_finding("ORD-AG-MATCHER", "warn", hook, "matcher #{hook.matcher.inspect} does not compile, so it never matches",
                                         "fix the regular expression")
          end
        elsif !Model::ANTIGRAVITY_TOOL_EVENTS.include?(hook.event) && hook.hook.key?("matcher")
          found << antigravity_finding("ORD-AG-MATCHER-IGNORED", "info", hook,
                                       "#{hook.event} is not a tool event, so Antigravity ignores the matcher #{hook.hook['matcher'].inspect}",
                                       "remove the matcher")
        end
        timeout = hook.hook["timeout"]
        if timeout.is_a?(Integer) && timeout <= 0
          found << antigravity_finding("ORD-AG-TIMEOUT", "warn", hook, "timeout #{timeout} is not a positive number of seconds",
                                       "use a positive timeout or remove it")
        end
        found
      end
    end

    def antigravity_groups(files)
      found = []
      files.each do |file|
        next unless file[:data].is_a?(Hash) && file[:error].nil?

        file[:data].each do |name, spec|
          next unless spec.is_a?(Hash)

          Model::ANTIGRAVITY_TOOL_EVENTS.each do |event|
            next unless spec[event].is_a?(Array)

            spec[event].each_with_index do |entry, index|
              next unless entry.is_a?(Hash)
              next if entry["hooks"].is_a?(Array) && !entry["hooks"].empty?

              found << antigravity_finding("ORD-AG-NOHOOKS", "warn", "#{file[:path]} #{name} #{event}[#{index}]",
                                           "this #{event} group has no hooks, so it runs nothing", "add handlers or remove the group")
            end
          end
        end
      end
      found
    end

    def antigravity_order(hooks)
      running = hooks.select do |hook|
        ANTIGRAVITY_RUNNING.include?(hook.status) && (hook.command || hook.type == "prompt")
      end
      running.group_by(&:event).filter_map do |event, list|
        specs = list.map { |hook| [hook.source_file, hook.hook_name] }.uniq
        next if specs.length < 2

        files = list.map(&:source_file).uniq
        ordered = list.select(&:absorbable)
        fix =
          if files.length == 1 && list.none?(&:plugin) && ordered.length >= 2
            "ordonnateur order #{event} #{ordered.map(&:id).join(' ')} --harness antigravity#{antigravity_project_flag(list.first)}"
          else
            "Antigravity keeps no order between hook specs or files"
          end
        antigravity_finding("ORD-AG-RANDOM-ORDER", "warn", event,
                            "#{list.length} handlers from #{specs.length} hook specs run on #{event}: these hooks run in an order that changes every session",
                            fix)
      end
    end

    def antigravity_project_flag(hook)
      return "" unless hook && hook.scope == "workspace" && hook.source_file

      " --project #{Shellwords.escape(File.dirname(hook.source_file, 2))}"
    end

    def antigravity_release_fix(event, path, scope)
      flags = scope == "workspace" ? " --scope workspace --project #{Shellwords.escape(File.dirname(path, 2))}" : ""
      "ordonnateur release #{event} --harness antigravity#{flags}"
    end

    def antigravity_ledgers(files, hooks, ledgers)
      found = []
      files.each do |file|
        ledger = ledgers[file[:path]]
        next unless ledger

        held = hooks.select do |hook|
          hook.source_file == file[:path] && hook.hook_name == Model::ANTIGRAVITY_MEMBER_SPEC && hook.plugin.nil?
        end.group_by(&:event)
        events = (ledger["events"].keys + held.keys).uniq
        events.each do |event|
          named = Array(ledger["events"][event]).filter_map { |entry| entry["digest"] if entry.is_a?(Hash) }
          present = Array(held[event]).map(&:digest)
          unless (named - present).empty?
            found << antigravity_finding("ORD-AG-LEDGER", "warn", "#{file[:path]} #{event}",
                                         "the ledger names #{(named - present).length} member(s) of #{event} that are no longer in the ordonnateur hook spec",
                                         antigravity_release_fix(event, file[:path], file[:scope]))
          end
          next if (present - named).empty?

          found << antigravity_finding("ORD-AG-LEDGER", "warn", "#{file[:path]} #{event}",
                                       "the ordonnateur hook spec holds #{(present - named).length} handler(s) on #{event} that the ledger does not name",
                                       antigravity_release_fix(event, file[:path], file[:scope]))
        end
      end
      found
    end
  end
end
