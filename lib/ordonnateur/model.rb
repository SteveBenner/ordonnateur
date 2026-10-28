#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "shellwords"

require_relative "canonical"
require_relative "matcher"

module Ordonnateur
  class Error < StandardError
    def exit_code = 2
  end

  class Usage < Error
  end

  class Refused < Error
  end

  class SettingsChanged < Error
    def exit_code = 3
  end

  class HarnessFileError < Error
    def exit_code = 4
  end

  module Model
    CLAUDE_EVENTS = %w[
      SessionStart Setup UserPromptSubmit UserPromptExpansion PreToolUse PermissionRequest PermissionDenied
      PostToolUse PostToolUseFailure PostToolBatch Notification MessageDisplay SubagentStart SubagentStop
      TaskCreated TaskCompleted Stop StopFailure TeammateIdle InstructionsLoaded ConfigChange CwdChanged
      DirectoryAdded FileChanged WorktreeCreate WorktreeRemove PreCompact PostCompact PreModelSwitch
      PostModelSwitch Elicitation ElicitationResult SessionEnd
    ].freeze

    CODEX_EVENTS = %w[
      SessionStart SessionEnd UserPromptSubmit PreToolUse PermissionRequest PostToolUse PreCompact
      PostCompact Stop SubagentStart SubagentStop Interrupt
    ].freeze

    HERMES_EVENTS = %w[
      pre_tool_call post_tool_call transform_terminal_output transform_tool_result transform_llm_output
      pre_llm_call post_llm_call on_stream_start on_stream_delta on_stream_end on_interim_message pre_verify
      pre_api_request post_api_request api_request_error pre_auxiliary_call post_auxiliary_call on_session_start
      on_session_end on_session_finalize on_session_reset on_session_delete on_skill_lifecycle subagent_start
      subagent_stop pre_command pre_transcription pre_gateway_dispatch gateway_platform_event
      post_gateway_admission post_compaction pre_approval_request post_approval_response
      on_human_input_request on_human_input_resolved on_room_member_activity agent_loop_stopped
      kanban_task_claimed kanban_task_completed kanban_task_blocked on_kanban_dispatch_tick
      on_kanban_task_updated on_kanban_worker_exited on_kanban_worker_spawned on_kanban_worker_stale_claim
    ].freeze

    HERMES_TOOL_EVENTS = %w[pre_tool_call post_tool_call].freeze

    HERMES_BLOCKING_EVENTS = %w[pre_tool_call].freeze

    HERMES_PYTHON_ONLY_EVENTS = %w[transform_api_error_classification].freeze

    HERMES_RESERVED_KEYS = %w[output_spill outbound].freeze

    ANTIGRAVITY_EVENTS = %w[SessionStart PreInvocation PreToolUse PostToolUse PostInvocation Stop].freeze

    ANTIGRAVITY_TOOL_EVENTS = %w[PreToolUse PostToolUse].freeze

    ANTIGRAVITY_TIMEOUT_DEFAULT = 30

    ANTIGRAVITY_MEMBER_SPEC = "ordonnateur"

    ANTIGRAVITY_DOT_DIRS = %w[.agents .agent _agents _agent].freeze

    ANTIGRAVITY_CLAUDE_TOOLS = %w[
      Bash Read Write Edit MultiEdit NotebookEdit Glob Grep LS WebFetch WebSearch Task TodoWrite
    ].freeze

    MATCHER_FIELD = {
      "PreToolUse" => "tool_name",
      "PostToolUse" => "tool_name",
      "PostToolUseFailure" => "tool_name",
      "PermissionRequest" => "tool_name",
      "PermissionDenied" => "tool_name",
      "SessionStart" => "source",
      "SessionEnd" => "reason",
      "Notification" => "notification_type",
      "SubagentStart" => "agent_type",
      "SubagentStop" => "agent_type",
      "PreCompact" => "trigger",
      "PostCompact" => "trigger"
    }.freeze

    NO_MATCHER_EVENTS = %w[
      UserPromptSubmit Stop PostToolBatch CwdChanged TeammateIdle TaskCreated TaskCompleted
      WorktreeCreate WorktreeRemove MessageDisplay
    ].freeze

    SEQUENCEABLE_EVENTS = %w[
      SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure Stop SubagentStart
      SubagentStop Notification PreCompact PostCompact
    ].freeze

    GUARD_EVENTS = %w[PreToolUse UserPromptSubmit PreCompact].freeze

    REFUSED_REASONS = {
      "SessionEnd" => "SessionEnd hooks share a 1.5-second budget; running them in sequence would exceed it.",
      "PermissionRequest" => "Pre-action permission flow; out of scope for 0.1."
    }.freeze

    OTHER_REFUSED_REASON = "Merge semantics not specified for 0.1."

    SCOPE_ORDER = %w[managed user project local].freeze

    CARD_SCHEMA = "ordonnateur.card/v1"

    module_function

    def default_timeout(event, harness: nil)
      return 60 if harness == "hermes"
      return ANTIGRAVITY_TIMEOUT_DEFAULT if harness == "antigravity"

      event == "UserPromptSubmit" ? 30 : 600
    end

    def refused_reason(event)
      REFUSED_REASONS.fetch(event, OTHER_REFUSED_REASON)
    end

    def events_for(harness)
      case harness
      when "codex" then CODEX_EVENTS
      when "hermes" then HERMES_EVENTS
      when "antigravity" then ANTIGRAVITY_EVENTS
      else CLAUDE_EVENTS
      end
    end

    def prefix(harness)
      case harness
      when "codex" then "codex"
      when "hermes" then "hm"
      when "antigravity" then "ag"
      else "cc"
      end
    end

    def dispatcher_command?(command)
      return false unless command.is_a?(String)

      words = Shellwords.split(command)
      words.length >= 2 && words[0].end_with?("/ordonnateur") && words[1] == "run"
    rescue ArgumentError
      false
    end

    def dispatcher_card_path(command)
      words = Shellwords.split(command)
      index = words.index("--card")
      path = index ? words[index + 1] : nil
      path&.sub(/\A\$HOME(?=\/|\z)/, ENV["HOME"].to_s)
    rescue ArgumentError
      nil
    end

    class Hook
      ATTRIBUTES = %i[
        harness scope source_file plugin plugin_root plugin_enabled event matcher hook line
        group_index handler_index id digest status absorbable reason member_position trust
        policy_protected policy_reason hook_name
      ].freeze

      attr_accessor(*ATTRIBUTES)

      def initialize(**values)
        ATTRIBUTES.each { |name| instance_variable_set("@#{name}", values[name]) }
        @absorbable = false if @absorbable.nil?
        refresh_identity
      end

      def refresh_identity
        return unless @event && @hook

        @digest = Canonical.digest(@matcher, @hook)
        scope_label = @plugin ? "plugin:#{@plugin}" : @scope
        @id = "#{Model.prefix(@harness)}:#{scope_label}:#{@event}:#{Canonical.short(@matcher, @hook)}"
      end

      def short
        @id.split(":").last
      end

      def command
        value = @hook["command"]
        value.is_a?(String) ? value : nil
      end

      def args
        value = @hook["args"]
        value.is_a?(Array) ? value : nil
      end

      def type
        @hook["type"]
      end

      def timeout
        value = @hook["timeout"]
        value.is_a?(Numeric) ? value : nil
      end

      def effective_timeout
        timeout || Model.default_timeout(@event, harness: @harness)
      end

      def dispatcher?
        Model.dispatcher_command?(command)
      end

      def to_h
        base = base_h
        base["hook_name"] = @hook_name if @harness == "antigravity"
        base
      end

      def base_h
        {
          "id" => @id,
          "harness" => @harness,
          "scope" => @scope,
          "plugin" => @plugin,
          "event" => @event,
          "matcher" => @matcher,
          "status" => @status,
          "timeout" => timeout,
          "command" => command,
          "args" => args,
          "type" => type,
          "hook" => @hook,
          "digest" => @digest,
          "source_file" => @source_file,
          "line" => @line,
          "group_index" => @group_index,
          "handler_index" => @handler_index,
          "absorbable" => @absorbable,
          "reason" => @reason,
          "protected" => @policy_protected ? true : false,
          "protected_reason" => @policy_reason,
          "trust" => @trust
        }
      end
    end
  end
end
