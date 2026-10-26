#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "securerandom"
require "tmpdir"

require_relative "matcher"
require_relative "model"
require_relative "harnesses/hermes"

module Ordonnateur
  module Payload
    TOOL_EVENTS = %w[PreToolUse PostToolUse PostToolUseFailure PermissionRequest].freeze

    module_function

    def parse_set(text)
      key, raw = text.split("=", 2)
      raise Usage, "--set needs key=json, got #{text.inspect}" if key.nil? || key.empty? || raw.nil?

      value = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        raw
      end
      [key, value]
    end

    def tool_input(tool, tmp)
      file = File.join(tmp, "ordonnateur-fire.txt")
      case tool
      when "Bash" then { "command" => "true", "description" => "ordonnateur test fire" }
      when "Write" then { "file_path" => file, "content" => "ordonnateur test fire\n" }
      when "Edit" then { "file_path" => file, "old_string" => "a", "new_string" => "b" }
      when "Read" then { "file_path" => file }
      else {}
      end
    end

    def build(event, tmp:, write: false, matcher: nil, cwd: nil, payload_file: nil, sets: [])
      transcript = File.join(tmp, "transcript.jsonl")
      File.write(transcript, "") if write
      directory = cwd ? File.expand_path(cwd) : tmp
      overrides = sets.to_h { |text| parse_set(text) }
      payload = {
        "session_id" => "ordonnateur-fire-#{SecureRandom.hex(4)}",
        "transcript_path" => transcript,
        "cwd" => directory,
        "permission_mode" => "default",
        "hook_event_name" => event
      }
      add_event_fields(payload, event, matcher, overrides, tmp, transcript)
      payload = read_file(payload_file) if payload_file
      overrides.each { |key, value| payload[key] = value }
      [payload, directory]
    end

    def read_file(path)
      data = JSON.parse(File.read(path))
      raise Usage, "#{path} must hold a JSON object" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError => e
      raise Usage, "#{path} does not parse: #{e.message.lines.first.to_s.strip}"
    rescue SystemCallError => e
      raise Usage, "#{path} is unreadable: #{e.message}"
    end

    def add_event_fields(payload, event, matcher, overrides, tmp, transcript)
      case event
      when "SessionStart" then payload["source"] = "startup"
      when "UserPromptSubmit" then payload["prompt"] = "ordonnateur test fire"
      when "Stop", "SubagentStop"
        payload["stop_hook_active"] = false
        payload["last_assistant_message"] = ""
      when "Notification"
        payload["message"] = "ordonnateur test fire"
        payload["notification_type"] = "idle_prompt"
      when "PreCompact", "PostCompact" then payload["trigger"] = "manual"
      when "SessionEnd" then payload["reason"] = "other"
      end
      if %w[SubagentStart SubagentStop].include?(event)
        payload["agent_id"] = "ordonnateur-fire-agent"
        payload["agent_type"] = "general-purpose"
      end
      payload["agent_transcript_path"] = transcript if event == "SubagentStop"
      return unless TOOL_EVENTS.include?(event)

      tool = overrides["tool_name"] || Matcher.first_alternative(matcher) || "Bash"
      payload["tool_name"] = tool
      payload["tool_use_id"] = "toolu_ordonnateur_fire"
      payload["tool_input"] = tool_input(tool, tmp)
      payload["tool_response"] = tool == "Bash" ? { "stdout" => "", "stderr" => "", "interrupted" => false } : {} if event == "PostToolUse"
      payload["error"] = "ordonnateur test fire" if event == "PostToolUseFailure"
    end

    def build_hermes(event, hook, tmp:, write: false, cwd: nil, payload_file: nil, sets: [])
      File.write(File.join(tmp, "transcript.jsonl"), "") if write
      directory = cwd ? File.expand_path(cwd) : tmp
      overrides = sets.to_h { |text| parse_set(text) }
      tool = nil
      input = nil
      if Model::HERMES_TOOL_EVENTS.include?(event)
        tool = overrides["tool_name"] || Matcher.first_alternative(hook&.matcher) || "Bash"
        input = tool_input(tool, tmp)
      end
      payload = {
        "hook_event_name" => event,
        "tool_name" => tool,
        "tool_input" => input,
        "session_id" => "ordonnateur-fire-#{SecureRandom.hex(4)}",
        "cwd" => directory,
        "profile" => "default",
        "extra" => {}
      }
      payload = read_file(payload_file) if payload_file
      overrides.each { |key, value| payload[key] = value }
      [payload, directory]
    end

    def environment_hermes(_cwd = nil)
      { "HERMES_HOME" => Harnesses::Hermes.home }
    end

    def environment(hook, cwd)
      env = {}
      env["CLAUDE_PROJECT_DIR"] = cwd if hook.harness == "claude-code"
      if hook.plugin_root
        env["CLAUDE_PLUGIN_ROOT"] = hook.plugin_root
        env["PLUGIN_ROOT"] = hook.plugin_root
      end
      env
    end
  end
end
