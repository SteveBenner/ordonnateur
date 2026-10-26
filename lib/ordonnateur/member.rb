#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "open3"

module Ordonnateur
  module Member
    CAP = 1024 * 1024
    BLOCKING = %w[block deny].freeze

    Result = Struct.new(:exit, :ms, :stdout, :stderr, :stdout_bytes, :truncated, :timed_out, :spawn_error, keyword_init: true)

    module_function

    def argv(hook)
      command = hook["command"]
      args = hook["args"]
      if args.is_a?(Array) && !args.empty?
        [command, *args.map(&:to_s)]
      else
        ["/bin/sh", "-c", command.to_s]
      end
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def run(hook, payload_json, timeout_s, env: {}, cwd: nil)
      started = clock
      unless hook["command"].is_a?(String) && !hook["command"].empty?
        return Result.new(exit: nil, ms: 0, stdout: "", stderr: "", stdout_bytes: 0, truncated: false,
                          timed_out: false, spawn_error: "hook has no command")
      end

      options = { pgroup: true }
      options[:chdir] = cwd if cwd
      begin
        stdin, stdout, stderr, thread = Open3.popen3(env, *argv(hook), **options)
      rescue SystemCallError => e
        return Result.new(exit: nil, ms: elapsed(started), stdout: "", stderr: e.message, stdout_bytes: 0,
                          truncated: false, timed_out: false, spawn_error: e.message)
      end
      out_sink = { buffer: +"", total: 0, truncated: false }
      err_sink = { buffer: +"", total: 0, truncated: false }
      writer = Thread.new do
        stdin.write(payload_json)
      rescue IOError, SystemCallError
        nil
      ensure
        begin
          stdin.close
        rescue IOError, SystemCallError
          nil
        end
      end
      readers = [reader(stdout, out_sink), reader(stderr, err_sink)]
      timed_out = wait(thread, timeout_s)
      readers.each { |t| t.join(2) || t.kill }
      writer.join(1) || writer.kill
      [stdout, stderr].each do |io|
        io.close
      rescue IOError, SystemCallError
        nil
      end
      status = thread.value
      Result.new(
        exit: exit_code(status), ms: elapsed(started), stdout: text(out_sink[:buffer]), stderr: text(err_sink[:buffer]),
        stdout_bytes: out_sink[:total], truncated: out_sink[:truncated] || err_sink[:truncated],
        timed_out: timed_out, spawn_error: nil
      )
    end

    def wait(thread, timeout_s)
      return false if thread.join(timeout_s)

      signal("TERM", thread.pid)
      unless thread.join(2)
        signal("KILL", thread.pid)
        thread.join
      end
      true
    end

    def signal(name, pid)
      Process.kill(name, -pid)
    rescue SystemCallError
      begin
        Process.kill(name, pid)
      rescue SystemCallError
        nil
      end
    end

    def reader(io, sink)
      Thread.new do
        loop do
          chunk = io.readpartial(65_536)
          sink[:total] += chunk.bytesize
          room = CAP - sink[:buffer].bytesize
          sink[:buffer] << chunk.byteslice(0, room) if room.positive?
          sink[:truncated] = true if chunk.bytesize > room
        end
      rescue EOFError, IOError, SystemCallError
        nil
      end
    end

    def exit_code(status)
      return status.exitstatus if status.exitstatus

      status.termsig ? 128 + status.termsig : nil
    end

    def elapsed(started)
      ((clock - started) * 1000).round
    end

    def text(buffer)
      buffer.dup.force_encoding(Encoding::UTF_8).scrub("?")
    end

    def hso(json)
      value = json && json["hookSpecificOutput"]
      value.is_a?(Hash) ? value : {}
    end

    def pre_decision(json)
      decision = hso(json)["permissionDecision"]
      decision ||= { "approve" => "allow", "block" => "deny" }[json["decision"]]
      %w[allow deny ask defer].include?(decision) ? decision : nil
    end

    def json_outcome(event, json)
      if event == "PreToolUse"
        decision = pre_decision(json)
        return decision if decision
      end
      return "block" if json["decision"] == "block" || json["continue"] == false

      "ok"
    end

    def interpret(event, result)
      stdout = result.stdout.strip
      stderr = result.stderr.strip
      json = nil
      if stdout.start_with?("{")
        parsed = begin
          JSON.parse(stdout)
        rescue JSON::ParserError
          nil
        end
        json = parsed if parsed.is_a?(Hash)
      end
      code = result.exit
      outcome =
        if result.spawn_error then "error"
        elsif result.timed_out then "timeout"
        elsif code == 2
          json = nil
          event == "PreToolUse" ? "deny" : "block"
        elsif json then json_outcome(event, json)
        elsif code == 0 then "ok"
        else "error"
        end
      json = nil if result.spawn_error
      {
        outcome: outcome, json: json, plain: json ? "" : stdout, stderr: stderr, exit: code, ms: result.ms,
        stdout_bytes: result.stdout_bytes, raw_stdout: result.stdout, raw_stderr: result.stderr
      }
    end

    def blocking?(entry)
      BLOCKING.include?(entry[:outcome])
    end

    def reason_of(entry)
      return entry[:stderr] if entry[:exit] == 2 && entry[:json].nil?

      json = entry[:json] || {}
      [hso(json)["permissionDecisionReason"], json["reason"], json["stopReason"]].find { |v| v.is_a?(String) && !v.empty? }.to_s
    end
  end
end
