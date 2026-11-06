#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"
require "open3"
require "securerandom"
require "tmpdir"

require_relative "../redact"

module Ordonnateur
  module Author
    class Standalone < Rplugin::Ports::Base
      TIMEOUT_S = 180
      KILL_GRACE_S = 2
      OUTPUT_CAP = 2_000_000
      DEFAULT_MODEL = "sonnet"
      MODEL_PATTERN = %r{\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}\z}.freeze
      DEFAULT_ROOT = File.expand_path("../../..", __dir__)
      CLAUDE_FLAGS = [
        "-p", "--output-format", "json", "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
        "--safe-mode", "--disable-slash-commands", "--no-session-persistence", "--permission-mode", "dontAsk"
      ].freeze
      CODEX_FLAGS = [
        "exec", "--disable", "shell_tool", "--disable", "hooks", "--disable", "plugins", "--disable", "apps",
        "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "--sandbox", "read-only",
        "--color", "never"
      ].freeze

      def open(context = nil)
        raise_unavailable("author standalone does not serve advisor.backend extension") if extension_context?(context)

        { id: SecureRandom.uuid, system: system_text(context), closed: false }
      end

      def turn(session, text, &on_event)
        raise_unavailable("session is closed") if session.nil? || session[:closed]

        prompt = text.to_s
        raise ArgumentError, "author turn needs text" if prompt.strip.empty?

        result = call_harness(compose(session[:system], prompt))
        done = { text: result, type: "done", session: session[:id] }
        on_event&.call(done)
        done
      end

      def close(session)
        return false if session.nil?

        session[:closed] = true
        true
      end

      private

      def extension_context?(context)
        context.respond_to?(:[]) && !context.is_a?(String) && (context[:backend] || context["backend"]) == "extension"
      end

      def system_text(context)
        return nil unless context.respond_to?(:[]) && !context.is_a?(String)

        value = context[:system] || context["system"]
        value.to_s.empty? ? nil : value.to_s
      end

      def compose(system, prompt)
        system ? "#{system}\n\n---\n\n#{prompt}" : prompt
      end

      def settings
        @settings ||= Rplugin::Settings.for(root || DEFAULT_ROOT)
      end

      def harness_name
        value = settings.get("advisor.harness").to_s
        %w[claude codex].include?(value) ? value : "claude"
      end

      def model_name
        value = settings.get("advisor.model").to_s.strip
        value.empty? ? DEFAULT_MODEL : value
      end

      def raise_unavailable(reason)
        raise Rplugin::PortUnavailable, "port author is unavailable: #{reason}"
      end

      def find_binary(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          path = File.join(dir, name)
          return path if File.file?(path) && File.executable?(path)
        end
        raise_unavailable("#{name} is not on PATH")
      end

      def call_harness(input)
        name = harness_name
        unless MODEL_PATTERN.match?(model_name)
          raise_unavailable("advisor.model must start with a letter or digit and use only letters, digits, and . _ : / - (up to 128 characters)")
        end
        binary = find_binary(name)
        Dir.mktmpdir("ordonnateur-advisor") do |dir|
          File.chmod(0o700, dir)
          argv, output_file = name == "codex" ? codex_argv(binary, dir) : claude_argv(binary)
          stdout, stderr, status = run_process(argv, input, dir)
          raise_unavailable("#{name} exited #{status.exitstatus.inspect}: #{brief(stderr)}") unless status.success?

          name == "codex" ? codex_text(output_file, stdout) : claude_text(stdout)
        end
      end

      def claude_argv(binary)
        [[binary, "--model", model_name, *CLAUDE_FLAGS], nil]
      end

      def codex_argv(binary, dir)
        output = File.join(dir, "answer.txt")
        argv = [binary, *CODEX_FLAGS, "-C", dir, "-o", output]
        argv.push("-m", model_name) unless model_name == DEFAULT_MODEL
        argv << "-"
        [argv, output]
      end

      def run_process(argv, input, dir)
        stdout = +""
        stderr = +""
        status = nil
        Open3.popen3({ "ORDONNATEUR_NESTED" => "1" }, *argv, chdir: dir, pgroup: true) do |stdin, out, err, waiter|
          pgid = waiter.pid
          writer = Thread.new do
            stdin.write(input)
          rescue Errno::EPIPE
            nil
          ensure
            stdin.close unless stdin.closed?
          end
          readers = [pump(out, stdout), pump(err, stderr)]
          status = waiter.join(TIMEOUT_S) ? waiter.value : nil
          if status.nil?
            terminate(pgid, waiter)
            raise_unavailable("the model call timed out after #{TIMEOUT_S} seconds")
          end
          writer.join
          readers.each(&:join)
        end
        [stdout, stderr, status]
      rescue SystemCallError => e
        raise_unavailable("the harness could not start: #{e.class.name}")
      end

      def pump(io, buffer)
        Thread.new do
          while (chunk = io.read(4096))
            buffer << chunk if buffer.bytesize < OUTPUT_CAP
          end
        rescue IOError
          nil
        end
      end

      def terminate(pgid, waiter)
        signal(pgid, "TERM")
        return if waiter.join(KILL_GRACE_S)

        signal(pgid, "KILL")
        waiter.join
      end

      def signal(pgid, name)
        Process.kill(name, -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def brief(text)
        Redact.text(text.to_s.lines.first(3).join(" ").strip)[0, 300]
      end

      def claude_text(stdout)
        parsed = JSON.parse(stdout)
        data = parsed.is_a?(Array) ? parsed.reverse.find { |item| item.is_a?(Hash) && item["type"] == "result" } : parsed
        return stdout.to_s.strip unless data.is_a?(Hash)

        raise_unavailable("claude reported an error: #{brief(data['result'])}") if data["is_error"] == true
        data["result"].to_s
      rescue JSON::ParserError
        stdout.to_s.strip
      end

      def codex_text(path, stdout)
        File.file?(path) ? File.read(path).strip : stdout.to_s.strip
      end
    end
  end
end
