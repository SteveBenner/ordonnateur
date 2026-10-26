#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "etc"
require "json"
require "open3"
require "set"
require "shellwords"
require "yaml"

require_relative "../model"
require_relative "../overlay"

module Ordonnateur
  module Harnesses
    module Hermes
      TRUTHY = %w[1 true yes on].freeze
      BLOCK_EXIT_CODE = 2
      DEFAULT_BLOCK_MESSAGE = "Blocked by shell hook."
      STDERR_MESSAGE_LIMIT = 400
      ANCHOR = /(?<![\w"'])[&*][\w-]+/.freeze

      module_function

      def name = "hermes"

      def home
        value = ENV["HERMES_HOME"]
        File.expand_path(value && !value.empty? ? value : "~/.hermes")
      end

      def config_path
        File.join(home, "config.yaml")
      end

      def allowlist_path
        File.join(home, "shell-hooks-allowlist.json")
      end

      def mode_of(path)
        File.file?(path) ? File.stat(path).mode & 0o7777 : nil
      end

      def read_text(path)
        overlaid, text = Overlay.read(path)
        return text if overlaid

        File.file?(path) ? File.read(path) : nil
      rescue SystemCallError, IOError => e
        raise HarnessFileError, "#{path} is unreadable: #{e.message}"
      end

      def parse_config(path, text)
        return {} if text.nil? || text.strip.empty?

        data = YAML.safe_load(text, aliases: false)
        return {} if data.nil?
        raise HarnessFileError, "#{path} is not a YAML mapping" unless data.is_a?(Hash)

        data
      rescue Psych::Exception => e
        raise HarnessFileError, "#{path} does not parse: #{e.message.lines.first.to_s.strip}"
      end

      def read_allowlist
        path = allowlist_path
        empty = { pairs: Set.new, entries: {}, readable: true }
        text = read_text(path)
        return empty if text.nil?

        data = JSON.parse(text.sub(/\A﻿/, ""))
        return empty.merge(readable: false) unless data.is_a?(Hash) && data["approvals"].is_a?(Array)

        entries = {}
        data["approvals"].each do |entry|
          next unless entry.is_a?(Hash) && entry["event"].is_a?(String) && entry["command"].is_a?(String)

          entries[[entry["event"], entry["command"]]] = entry
        end
        { pairs: Set.new(entries.keys), entries: entries, readable: true }
      rescue JSON::ParserError, HarnessFileError
        empty.merge(readable: false)
      end

      def truthy_string?(value)
        value.is_a?(String) && TRUTHY.include?(value.strip.downcase)
      end

      def opt_in(data = {})
        return "env" if truthy_string?(ENV["HERMES_ACCEPT_HOOKS"])

        value = data.is_a?(Hash) ? data["hooks_auto_accept"] : nil
        return "config" if value == true || truthy_string?(value)

        nil
      end

      def blank_line?(line)
        line.strip.empty? || line.lstrip.start_with?("#")
      end

      def indent_of(line)
        line[/\A */].length
      end

      def item_start?(line, indent)
        line[indent, 2] == "- " || line.strip == "-"
      end

      def event_layout(text, event)
        return [nil, "no config text"] if text.nil?

        lines = text.lines
        top = lines.index { |line| line.match?(/\Ahooks:[ \t]*(#.*)?\r?\n?\z/) }
        return [nil, "hooks is not a block mapping"] unless top

        stop = ((top + 1)...lines.length).find { |i| !blank_line?(lines[i]) && indent_of(lines[i]).zero? } || lines.length
        first = ((top + 1)...stop).find { |i| !blank_line?(lines[i]) }
        return [nil, "hooks has no entries"] unless first

        child = indent_of(lines[first])
        key = /\A {#{child}}(?:"#{Regexp.escape(event)}"|'#{Regexp.escape(event)}'|#{Regexp.escape(event)})[ \t]*:(.*)\z/m
        found = ((top + 1)...stop).select { |i| indent_of(lines[i]) == child && lines[i].match?(key) }
        return [nil, "#{event} is not under hooks"] if found.empty?
        return [nil, "#{event} appears more than once"] if found.length > 1

        key_index = found.first
        rest = lines[key_index].match(key)[1].sub(/#.*\z/, "").strip
        return [nil, "#{event} is not a block sequence"] unless rest.empty?

        block_layout(lines, key_index, stop)
      end

      def block_layout(lines, key_index, stop)
        head = ((key_index + 1)...stop).find { |i| !blank_line?(lines[i]) }
        return [nil, "the list is empty"] unless head

        item_indent = indent_of(lines[head])
        key_indent = indent_of(lines[key_index])
        return [nil, "the list is empty"] if item_indent < key_indent || !item_start?(lines[head], item_indent)

        starts = []
        finish = stop
        low_comment = false
        ((key_index + 1)...stop).each do |i|
          line = lines[i]
          if blank_line?(line)
            low_comment = true if !line.strip.empty? && indent_of(line) < item_indent
            next
          end
          indent = indent_of(line)
          if indent < item_indent || (indent == item_indent && !item_start?(line, item_indent))
            finish = i
            break
          end
          if indent == item_indent
            return [nil, "a comment between items cannot be attached to an item"] if low_comment && !starts.empty?

            low_comment = false
            starts << i
          end
        end
        last = (starts.last...finish).select { |i| !blank_line?(lines[i]) }.last
        ends = starts.drop(1) + [last + 1]
        ranges = starts.zip(ends)
        body = ranges.flat_map { |from, to| lines[from...to] }.reject { |line| blank_line?(line) }
        return [nil, "the list uses an anchor or alias"] if body.any? { |line| line.match?(ANCHOR) }

        [{ lines: lines, ranges: ranges, key_index: key_index }, nil]
      end

      def entry_problem(raw)
        return "must be a mapping with a command key" unless raw.is_a?(Hash)

        command = raw["command"]
        return "is missing a non-empty command field" unless command.is_a?(String) && !command.strip.empty?

        nil
      end

      def entry_timeout(raw)
        value = raw["timeout"]
        value.is_a?(Numeric) ? value : nil
      end

      def fail_closed?(raw, event)
        value = raw.key?("fail_closed") ? raw["fail_closed"] : raw["failClosed"]
        value == true && Model::HERMES_BLOCKING_EVENTS.include?(event)
      end

      def pinned_reason(hook)
        if hook.policy_protected
          "is a guard: #{hook.policy_reason || 'protected by the policy engine'}"
        elsif fail_closed?(hook.hook, hook.event)
          "is a guard: fail_closed is true on #{hook.event}"
        end
      end

      def pinned?(hook)
        !pinned_reason(hook).nil?
      end

      def status_for(pair, allowlist, opt)
        if allowlist[:pairs].include?(pair) then "allowlisted"
        elsif opt then "auto-accepted"
        else "not-allowlisted"
        end
      end

      def hooks_from(data, text, path, allowlist: nil, opt_in: nil)
        allowlist ||= read_allowlist
        opt = opt_in || self.opt_in(data)
        block = data["hooks"]
        notes = []
        bad = []
        hooks = []
        unless block.nil? || block.is_a?(Hash)
          notes << "#{path}: hooks is not a mapping; no Hermes hooks read"
          return { hooks: hooks, notes: notes, bad_entries: bad }
        end
        (block || {}).each do |event, entries|
          next if Model::HERMES_RESERVED_KEYS.include?(event)
          next if entries.nil?

          unless event.is_a?(String) && entries.is_a?(Array)
            notes << "#{path}: hooks.#{event} is not a list; skipped"
            next
          end
          layout, = event_layout(text, event)
          lines = layout && layout[:ranges].length == entries.length ? layout[:ranges] : nil
          entries.each_with_index do |raw, index|
            problem = entry_problem(raw)
            if problem
              bad << [event, index, problem]
              next
            end
            pair = [event, raw["command"].strip]
            status = status_for(pair, allowlist, opt)
            entry = allowlist[:entries][pair]
            hooks << Model::Hook.new(
              harness: name, scope: "user", source_file: path, event: event,
              matcher: raw["matcher"].is_a?(String) ? raw["matcher"] : nil, hook: raw,
              line: lines ? lines[index][0] + 1 : nil, group_index: index, handler_index: 0,
              plugin_enabled: true, status: status,
              trust: {
                "state" => status,
                "approved_at" => entry && entry["approved_at"].is_a?(String) ? entry["approved_at"] : nil,
                "script_mtime_at_approval" =>
                  entry && entry["script_mtime_at_approval"].is_a?(String) ? entry["script_mtime_at_approval"] : nil,
                "opt_in" => opt
              }
            )
          end
        end
        { hooks: hooks, notes: notes, bad_entries: bad }
      end

      def watch_files(_loaded = nil)
        [config_path, allowlist_path]
      end

      def load(_root = nil)
        path = config_path
        text = read_text(path)
        data = parse_config(path, text)
        allowlist = read_allowlist
        opt = opt_in(data)
        built = hooks_from(data, text, path, allowlist: allowlist, opt_in: opt)
        notes = built[:notes]
        if !allowlist[:readable] && File.file?(allowlist_path)
          notes << "#{allowlist_path} is unreadable or malformed; Hermes treats every hook as not approved"
        end
        configured = built[:hooks].map { |hook| [hook.event, hook.command.strip] }
        stale = allowlist[:pairs].to_a.reject { |pair| configured.include?(pair) }
        {
          config_path: path, allowlist_path: allowlist_path, data: data, text: text, hooks: built[:hooks],
          notes: notes, stale: stale, opt_in: opt, allowlist_readable: allowlist[:readable],
          allowlist: allowlist, bad_entries: built[:bad_entries]
        }
      end

      def expand_user(command)
        match = command.match(/\A~([^\/]*)/)
        return command unless match

        user = match[1]
        base =
          if user.empty? then ENV["HOME"].to_s.empty? ? Dir.home : ENV["HOME"]
          else
            begin
              Etc.getpwnam(user).dir
            rescue ArgumentError
              nil
            end
          end
        base ? base + command[match[0].length..] : command
      end

      def run_hook(hook, payload_json, timeout:, env: {}, cwd: nil)
        result = { returncode: nil, stdout: "", stderr: "", timed_out: false, elapsed_ms: 0, error: nil }
        begin
          argv = Shellwords.split(expand_user(hook.command.to_s.strip))
        rescue ArgumentError => e
          result[:error] = "command #{hook.command.inspect} cannot be parsed: #{e.message}"
          return result
        end
        if argv.empty?
          result[:error] = "empty command"
          return result
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        options = { pgroup: true }
        options[:chdir] = cwd if cwd
        begin
          stdin, stdout, stderr, waiter = Open3.popen3(env || {}, *argv, **options)
        rescue Errno::ENOENT
          result[:error] = "command not found"
          return result
        rescue Errno::EACCES
          result[:error] = "command not executable"
          return result
        rescue SystemCallError, IOError => e
          result[:error] = e.message
          return result
        end
        out_reader = Thread.new { stdout.read.to_s }
        err_reader = Thread.new { stderr.read.to_s }
        writer = Thread.new do
          stdin.write(payload_json)
        rescue SystemCallError, IOError
          nil
        ensure
          begin
            stdin.close
          rescue IOError
            nil
          end
        end
        finished = waiter.join(timeout)
        if finished.nil?
          begin
            Process.kill("KILL", -waiter.pid)
          rescue SystemCallError
            nil
          end
          waiter.join(1)
          result[:timed_out] = true
        else
          result[:returncode] = waiter.value.exitstatus
        end
        writer.join(1)
        result[:stdout] = clean(out_reader.value) if out_reader.join(1)
        result[:stderr] = clean(err_reader.value) if err_reader.join(1)
        result[:elapsed_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        result
      ensure
        [stdout, stderr].each do |io|
          io&.close unless io&.closed?
        end
      end

      def clean(text)
        text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      def present?(value)
        !(value.nil? || value == false || value == "" || value == [] || value == {} || value == 0)
      end

      def block_message(primary, secondary)
        raw = present?(primary) ? primary : secondary
        raw.is_a?(String) && !raw.empty? ? raw : DEFAULT_BLOCK_MESSAGE
      end

      def parse_pre_tool_call(data)
        [["action", "message", "reason", "args"], ["decision", "reason", "message", "tool_input"]].each do |verb, primary, secondary, _|
          return { "action" => "block", "message" => block_message(data[primary], data[secondary]) } if data[verb] == "block"
        end
        [["action", "message", "reason", "args"], ["decision", "reason", "message", "tool_input"]].each do |verb, _, _, payload|
          return { "action" => "modify", "args" => data[payload] } if data[verb] == "modify" && data[payload].is_a?(Hash)
        end
        if data["action"] == "approve"
          directive = { "action" => "approve" }
          %w[message rule_key].each do |key|
            value = data[key]
            directive[key] = value.strip if value.is_a?(String) && !value.strip.empty?
          end
          return directive
        end
        nil
      end

      def parse_pre_verify(data)
        action = (data["action"] || data["decision"]).to_s.strip.downcase
        message = data["message"] || data["reason"]
        return nil unless %w[continue block].include?(action) && message.is_a?(String) && !message.strip.empty?

        { "action" => "continue", "message" => message.strip }
      end

      def parse_context(data)
        context = data["context"]
        context.is_a?(String) && !context.strip.empty? ? { "context" => context } : nil
      end

      def parse_response(event, stdout)
        text = stdout.to_s.strip
        return nil if text.empty?

        data = JSON.parse(text)
        return nil unless data.is_a?(Hash)

        case event
        when "pre_tool_call" then parse_pre_tool_call(data)
        when "pre_verify" then parse_pre_verify(data)
        else parse_context(data)
        end
      rescue JSON::ParserError
        nil
      end

      def json_object?(text)
        JSON.parse(text).is_a?(Hash)
      rescue JSON::ParserError
        false
      end

      def fail_closed_block(command, reason)
        { "action" => "block", "message" => "hook #{command} failed closed: #{reason}" }
      end

      def outcome_of(outcome, directive, message = nil)
        { outcome: outcome, blocked: !directive.nil? && directive["action"] == "block", directive: directive, message: message }
      end

      def interpret(event, result, fail_closed: false, command: nil)
        blocking = Model::HERMES_BLOCKING_EVENTS.include?(event)
        closed = fail_closed && blocking
        if result[:error] || result[:timed_out]
          reason = result[:error] || "timed out"
          kind = result[:error] ? "error" : "timeout"
          if closed
            directive = fail_closed_block(command, reason)
            return outcome_of("fail_closed_#{kind}", directive, directive["message"])
          end
          return outcome_of("fail_open_#{kind}", nil, reason)
        end
        stderr = result[:stderr].to_s.strip
        if result[:returncode] == BLOCK_EXIT_CODE && blocking
          parsed = parse_response(event, result[:stdout])
          return outcome_of("blocked", parsed, parsed["message"]) if parsed && parsed["action"] == "block"

          message = stderr[0, STDERR_MESSAGE_LIMIT]
          message = DEFAULT_BLOCK_MESSAGE if message.nil? || message.empty?
          return outcome_of("blocked", { "action" => "block", "message" => message }, message)
        end
        stdout = result[:stdout].to_s.strip
        parsed = parse_response(event, stdout)
        nonzero = result[:returncode] != 0
        if parsed.nil? && closed && nonzero
          directive = fail_closed_block(command, "hook exited #{result[:returncode]} with no directive")
          return outcome_of("fail_closed_exit", directive, directive["message"])
        end
        if parsed.nil? && closed && !stdout.empty? && !json_object?(stdout)
          directive = fail_closed_block(command, "unparseable stdout (expected a JSON object)")
          return outcome_of("fail_closed_output", directive, directive["message"])
        end
        return outcome_of("directive", parsed, parsed["message"] || parsed["context"]) if parsed

        outcome_of(nonzero ? "warn" : "ok", nil, nonzero ? stderr[0, STDERR_MESSAGE_LIMIT] : nil)
      end
    end
  end
end
