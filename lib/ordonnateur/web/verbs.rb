#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "stringio"
require "yaml"

require_relative "../advisor"
require_relative "../author/standalone"
require_relative "../setup_plan"
require_relative "../untangle"

module Ordonnateur
  module Web
    class Verbs
      HARNESSES = %w[all claude-code codex hermes antigravity].freeze
      HEALS = %w[none preview apply].freeze
      INTERVIEWS = %w[saved skip].freeze
      SCOPES = %w[user local].freeze
      RUN_KEYS = {
        "untangle" => %w[verb project model harness heal],
        "plan" => %w[verb project model answers interview scope]
      }.freeze
      ANSWER_KEYS = %w[goal harnesses unattended constraint].freeze
      SETTING_KEYS = %w[untangle.heal advisor.backend advisor.harness advisor.model].freeze
      HEAL_SWITCH = "ORDONNATEUR_HEAL_DISABLED"
      ADVISOR_SWITCH = "ORDONNATEUR_ADVISOR_DISABLED"
      MODEL_MESSAGE = "advisor.model must start with a letter or digit and use only letters, digits, and . _ : / - (up to 128 characters)"
      MAX_IDS = 20
      MAX_PROPOSALS = 100

      def initialize(ports:, settings:, runs:, apply_lock:)
        @ports = ports
        @settings = settings
        @runs = runs
        @apply_lock = apply_lock
      end

      def health(query)
        harness = query["harness"].to_s.empty? ? "all" : query["harness"]
        raise Failure.new(422, "invalid", "harness must be one of #{HARNESSES.join(', ')}") unless HARNESSES.include?(harness)

        project = project_param(query["project"].to_s.empty? ? nil : query["project"])
        engine = untangle
        engine.scan_report(harness, project || Web.empty_root).merge(
          "heal_mode" => engine.heal_mode, "heal_locked_by" => engine.heal_locked_by
        )
      end

      def start_run(raw)
        verb = raw["verb"]
        raise Failure.new(422, "invalid", "verb must be untangle or plan") unless RUN_KEYS.key?(verb)

        extra = raw.keys - RUN_KEYS.fetch(verb)
        raise Failure.new(422, "invalid", "unknown option #{extra.first} for #{verb}") unless extra.empty?
        raise Failure.new(422, "invalid", "model must be true or false") unless [true, false].include?(raw["model"])

        ensure_enabled!
        project = project_param(raw["project"])
        runner = verb == "untangle" ? untangle_runner(raw, project) : plan_runner(raw, project)
        @runs.start(verb, &runner)
      end

      def runs_overview
        @runs.overview
      end

      def run(id)
        @runs.fetch(id)
      end

      def proposals(query)
        project = project_param(query["project"].to_s.empty? ? nil : query["project"])
        setup_plan.web_state(project || Web.empty_root)
      end

      def store_proposals(raw)
        project = project_param(raw["project"])
        scope = scope_param(raw["scope"], project)
        list = raw["proposals"]
        unless list.is_a?(Array) && !list.empty? && list.length <= MAX_PROPOSALS
          raise Failure.new(422, "invalid", "proposals must be a list of 1 to #{MAX_PROPOSALS} proposals")
        end

        report = setup_plan.web_ingest(list, { project: project || Web.empty_root, scope: scope })
        { "stored" => report["proposals"].length, "refused" => report["refused"] }
      end

      def apply_proposals(raw)
        ids = raw["ids"]
        unless ids.is_a?(Array) && !ids.empty? && ids.length <= MAX_IDS && ids.all? { |id| id.is_a?(String) && !id.empty? }
          raise Failure.new(422, "invalid", "ids must be a list of 1 to #{MAX_IDS} proposal ids")
        end
        unless [nil, true, false].include?(raw["allow_widening"])
          raise Failure.new(422, "invalid", "allow_widening must be true or false")
        end

        project = project_param(raw["project"])
        widening = raw["allow_widening"] == true
        if widening && (ids.uniq.length != 1 || raw["confirm"] != ids.first)
          raise Failure.new(422, "confirm_required", "widening access applies one proposal at a time, with its id typed", { proposal_id: ids.first })
        end
        ensure_enabled!
        results = setup_plan.web_apply(ids.uniq, { project: project || Web.empty_root, allow_widening: widening })
        { "applied" => results }
      end

      def settings
        {
          "settings" => SETTING_KEYS.map { |key| setting_row(key) },
          "extension_available" => extension_available?
        }
      end

      def put_setting(key, raw)
        entry = setting_entry(key)
        ensure_enabled!
        value = raw["value"]
        raise Failure.new(422, "invalid", "value must be text") unless value.is_a?(String)

        check_value!(entry, value)
        lock = locked_by(key)
        raise Failure.new(422, "locked", "#{key} is locked by #{lock}", { locked_by: lock }) if lock
        if key == "untangle.heal" && value == "auto" && raw["confirm"] != "auto"
          raise Failure.new(422, "confirm_required", "type auto to turn on automatic healing", { expected: "auto" })
        end

        @apply_lock.synchronize do
          judge!(file_after { |values| values[key] = value })
          change(key) { @settings.set(key, value) }
        end
      end

      def delete_setting(key)
        setting_entry(key)
        ensure_enabled!
        lock = locked_by(key)
        raise Failure.new(422, "locked", "#{key} is locked by #{lock}", { locked_by: lock }) if lock

        @apply_lock.synchronize do
          judge!(file_after { |values| values.delete(key) })
          change(key) { @settings.unset(key) }
        end
      end

      private

      def untangle
        Untangle.new(ports: @ports, settings: @settings, lock: @apply_lock)
      end

      def setup_plan
        SetupPlan.new(ports: @ports, settings: @settings, lock: @apply_lock)
      end

      def project_param(value)
        return nil if value.nil?

        unless value.is_a?(String) && value.start_with?("/") && !value.include?("\0") && File.directory?(value)
          raise Failure.new(422, "invalid", "project must be an absolute path to an existing directory")
        end
        value
      end

      def scope_param(value, project)
        scope = value.nil? ? "user" : value
        raise Failure.new(422, "invalid", "scope must be user or local") unless SCOPES.include?(scope)
        raise Failure.new(422, "invalid", "local scope needs a project") if scope == "local" && project.nil?

        scope
      end

      def ensure_enabled!
        return if @settings.on?("web.enabled")

        raise Failure.new(403, "disabled", "ordonnateur web is disabled", { reason: "disabled" })
      end

      def untangle_runner(raw, project)
        harness = raw["harness"].nil? ? "all" : raw["harness"]
        raise Failure.new(422, "invalid", "harness must be one of #{HARNESSES.join(', ')}") unless HARNESSES.include?(harness)

        heal = raw["heal"].nil? ? "none" : raw["heal"]
        raise Failure.new(422, "invalid", "heal must be none, preview, or apply") unless HEALS.include?(heal)

        engine = untangle
        if heal != "none" && engine.heal_mode == "off"
          reason = engine.heal_locked_by ? "#{engine.heal_locked_by}=1 turns healing off" : "untangle.heal is off; set it to plan or auto first"
          raise Failure.new(422, "invalid", "healing is not allowed: #{reason}")
        end
        options = {
          harness: harness, project: project || Web.empty_root, no_model: raw["model"] == false, json: true,
          heal: heal != "none", apply: heal == "apply", preview_only: heal == "preview"
        }
        ->(out) { engine.call(options, out) }
      end

      def plan_runner(raw, project)
        scope = scope_param(raw["scope"], project)
        interview = raw["interview"].nil? ? "saved" : raw["interview"]
        raise Failure.new(422, "invalid", "interview must be saved or skip") unless INTERVIEWS.include?(interview)

        engine = setup_plan
        answers = answers_param(raw["answers"])
        if answers.nil? && interview == "saved" && engine.profile.nil?
          raise Failure.new(422, "answers_needed", "answer the questions, skip them, or save a profile first")
        end
        options = {
          project: project || Web.empty_root, scope: scope, no_model: raw["model"] == false, json: true,
          answers_data: answers, no_interview: interview == "skip" && answers.nil?
        }
        ->(out) { engine.call(options, out, input: StringIO.new) }
      end

      def answers_param(value)
        return nil if value.nil?
        raise Failure.new(422, "invalid", "answers must be an object") unless value.is_a?(Hash)

        extra = value.keys - ANSWER_KEYS
        raise Failure.new(422, "invalid", "unknown answer #{extra.first}") unless extra.empty?
        %w[goal unattended constraint].each do |key|
          next if value[key].nil? || value[key].is_a?(String)

          raise Failure.new(422, "invalid", "#{key} must be text")
        end
        harnesses = value["harnesses"]
        unless harnesses.nil? || (harnesses.is_a?(Array) && harnesses.all? { |item| SetupPlan::HARNESSES.include?(item) })
          raise Failure.new(422, "invalid", "harnesses must be a list drawn from #{SetupPlan::HARNESSES.join(', ')}")
        end
        value
      end

      def setting_entry(key)
        raise Failure.new(404, "not_found", "no such setting") unless SETTING_KEYS.include?(key)

        @settings.entry(key)
      end

      def locked_by(key)
        if key == "untangle.heal"
          ENV[HEAL_SWITCH] == "1" ? HEAL_SWITCH : nil
        else
          ENV[ADVISOR_SWITCH] == "1" ? ADVISOR_SWITCH : nil
        end
      end

      def check_value!(entry, value)
        key = entry["key"]
        if entry["type"] == "enum" && !Array(entry["options"]).include?(value)
          raise Failure.new(422, "invalid", "#{key} must be one of #{Array(entry['options']).join(', ')}")
        end
        return unless key == "advisor.model" && !Author::Standalone::MODEL_PATTERN.match?(value)

        raise Failure.new(422, "invalid", MODEL_MESSAGE)
      end

      def setting_row(key)
        entry = @settings.entry(key)
        {
          "key" => key, "type" => entry["type"], "options" => entry["options"], "value" => @settings.get(key),
          "default" => entry["default"], "layer" => @settings.layer(key), "description" => entry["description"],
          "locked_by" => locked_by(key)
        }
      end

      def extension_available?
        Array(@ports.chain("author")).any? { |name| name.to_s.start_with?(Advisor::EXTENSION_PREFIX) }
      rescue Rplugin::PortUnavailable
        false
      end

      def file_after
        values, = @settings.read_file(@settings.user_file)
        values = (values || {}).dup
        yield values
        YAML.dump({ "schema" => Rplugin::Settings::FILE_SCHEMA, "values" => values })
      end

      def judge!(content)
        verdict = @ports.policy.judge(
          tool_name: "Write", tool_input: { "file_path" => @settings.user_file, "content" => content }, cwd: Dir.home
        )
        name = verdict[:verdict].to_s
        return unless %w[warn deny].include?(name)

        verb = name == "deny" ? "denies" : "asks about"
        raise Failure.new(422, "policy_#{name}", "the policy #{verb} writing #{@settings.user_file}: #{verdict[:reason]}", { rule_id: verdict[:rule_id] })
      end

      def change(key)
        result = yield
        { "key" => key, "value" => result[:to], "layer" => @settings.layer(key), "from" => result[:from] }
      rescue Rplugin::Refused => e
        raise Failure.new(422, "refused", e.message)
      end
    end
  end
end
