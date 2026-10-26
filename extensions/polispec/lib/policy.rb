#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "open3"
require "securerandom"
require "shellwords"

module Rplugin
  module Adapters
    module Ordonnateur
      module Polispec
        class Policy < Rplugin::Ports::Base
          TIMEOUT_S = 20
          VERDICTS = %w[allow warn deny].freeze

          def judge(tool_name:, tool_input:, cwd:)
            payload = {
              "session_id" => "ordonnateur-policy-#{SecureRandom.hex(4)}",
              "hook_event_name" => "PreToolUse",
              "cwd" => cwd,
              "tool_name" => tool_name,
              "tool_input" => tool_input
            }
            answer = explain(JSON.generate(payload))
            interpret(answer)
          rescue StandardError => e
            failure(e.message)
          end

          def protected?(command:, args: nil, plugin: nil)
            text = command.to_s
            first = begin
              Shellwords.split(text).first.to_s
            rescue ArgumentError
              ""
            end
            program = File.basename(first)
            hit = text.include?("/bin/polispec-guard") || %w[polispec polispec-guard].include?(program) ||
                  plugin.to_s.start_with?("polispec@")
            { protected: hit, reason: hit ? "polispec's own hook" : nil }
          end

          private

          def explain(stdin_text)
            out = err = nil
            status = nil
            Open3.popen3("polispec", "explain", "--harness", "claude", "--json") do |stdin, stdout, stderr, thread|
              writer = Thread.new do
                stdin.write(stdin_text)
                stdin.close
              rescue IOError, SystemCallError
                nil
              end
              out_reader = Thread.new { stdout.read }
              err_reader = Thread.new { stderr.read }
              unless thread.join(TIMEOUT_S)
                begin
                  Process.kill("KILL", thread.pid)
                rescue SystemCallError
                  nil
                end
                thread.join
                raise "timed out after #{TIMEOUT_S} seconds"
              end
              writer.join
              out = out_reader.value
              err = err_reader.value
              status = thread.value
            end
            raise "exit #{status.exitstatus}: #{err.to_s.lines.first.to_s.strip}" unless status.success?

            JSON.parse(out)
          end

          def interpret(answer)
            raise "unparsable output" unless answer.is_a?(Hash)

            verdict = answer["verdict"]
            raise "unknown verdict #{verdict.inspect}" unless VERDICTS.include?(verdict)

            control = answer["control"].is_a?(Hash) ? answer["control"]["verdict"] : nil
            raise "unknown control verdict #{control.inspect}" unless control.nil? || VERDICTS.include?(control) || control == "ask"

            final =
              if verdict == "deny" || control == "deny" then "deny"
              elsif verdict == "warn" || %w[ask warn].include?(control) then "warn"
              else "allow"
              end
            { verdict: final, rule_id: answer["rule_id"], reason: answer["reason"].to_s, source: "polispec" }
          end

          def failure(detail)
            { verdict: "deny", rule_id: nil, reason: "polispec did not answer: #{detail}", source: "polispec" }
          end
        end
      end
    end
  end
end
