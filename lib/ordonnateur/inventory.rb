#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "model"
require_relative "card"
require_relative "harnesses/claude_code"
require_relative "harnesses/codex"
require_relative "harnesses/hermes"
require_relative "harnesses/antigravity"

module Ordonnateur
  module Inventory
    Result = Struct.new(:hooks, :notes, :root, :claude, :codex, :hermes, :antigravity, :members, :cards, keyword_init: true) do
      def initialize(**values)
        super
        self.members ||= []
        self.cards ||= {}
      end
    end

    HARNESSES = %w[claude-code codex hermes antigravity all].freeze

    HARNESS_RANK = { "claude-code" => 0, "codex" => 1, "hermes" => 2, "antigravity" => 3 }.freeze

    module_function

    def load(harness: "all", project: nil, unguarded: {}, policy: nil)
      raise Usage, "harness must be one of #{HARNESSES.join(', ')}" unless HARNESSES.include?(harness)

      root = Harnesses::ClaudeCode.project_root(project)
      claude = %w[all claude-code].include?(harness) ? Harnesses::ClaudeCode.load(root) : nil
      codex = %w[all codex].include?(harness) ? Harnesses::Codex.load(root) : nil
      hermes = %w[all hermes].include?(harness) ? Harnesses::Hermes.load(root) : nil
      antigravity = %w[all antigravity].include?(harness) ? Harnesses::Antigravity.load(root, File.expand_path(project || Dir.pwd)) : nil
      notes = Array(claude && claude[:notes]) + Array(codex && codex[:notes]) + Array(hermes && hermes[:notes]) +
              Array(antigravity && antigravity[:notes])
      hooks = []
      hooks.concat(classify_claude(claude, unguarded, policy)) if claude
      hooks.concat(codex[:hooks]) if codex
      hooks.concat(classify_hermes(hermes, policy)) if hermes
      hooks.concat(classify_antigravity(antigravity, policy)) if antigravity
      mark_protected(hooks, policy)
      Result.new(
        hooks: order(hooks), notes: notes, root: root, claude: claude, codex: codex, hermes: hermes,
        antigravity: antigravity
      )
    end

    def load_full(harness: "all", project: nil, policy: nil)
      root = Harnesses::ClaudeCode.project_root(project)
      result = load(harness: harness, project: project, unguarded: Card.unguarded_map(root), policy: policy)
      result.members = []
      if %w[all claude-code].include?(harness)
        Card.cards(root).each do |scope, entry|
          result.cards[scope] = entry
          result.members.concat(Card.member_hooks(entry[:card], scope, entry[:path]))
        end
        mark_protected(result.members, policy)
      end
      result.hooks = order(result.hooks + result.members)
      result
    end

    def order(hooks)
      indexed = hooks.each_with_index.to_a
      indexed.sort_by do |hook, index|
        events = Model.events_for(hook.harness)
        [HARNESS_RANK.fetch(hook.harness, 3), events.index(hook.event) || events.length, index]
      end.map(&:first)
    end

    def mark_protected(hooks, policy)
      return unless policy

      hooks.each do |hook|
        next if hook.command.nil?

        answer = policy.protected?(command: hook.command, args: hook.args, plugin: hook.plugin)
        hook.policy_protected = answer[:protected] ? true : false
        hook.policy_reason = answer[:reason]
      end
    end

    def guard?(hook, unguarded = [])
      return true if hook.hook["onFailure"] == "block" || hook.policy_protected

      Model::GUARD_EVENTS.include?(hook.event) && !Array(unguarded).include?(hook.digest)
    end

    def hard_guard?(hook)
      hook.hook["onFailure"] == "block" || hook.policy_protected
    end

    def twin_files(claude, hook)
      key = Canonical.json(hook.hook)
      claude[:hooks].select do |other|
        other.plugin.nil? && other.event == hook.event && other.source_file != hook.source_file &&
          Canonical.json(other.hook) == key
      end.map(&:source_file).uniq
    end

    def refusal_reasons(claude, hook, unguarded)
      reasons = []
      reasons << "is not in the user or local settings file" unless %w[user local].include?(hook.scope) && hook.plugin.nil?
      unless Model::SEQUENCEABLE_EVENTS.include?(hook.event)
        reasons << "is on #{hook.event}, which cannot be sequenced: #{Model.refused_reason(hook.event)}"
      end
      if guard?(hook, unguarded)
        reasons << if hook.policy_protected
                     "is a guard: #{hook.policy_reason || 'protected by the policy engine'}, which cannot be unguarded"
                   elsif hard_guard?(hook)
                     "is a guard: onFailure is block, which cannot be unguarded"
                   else
                     "is a guard on #{hook.event}; run `ordonnateur unguard` to allow sequencing it"
                   end
      end
      reasons << "type is #{hook.type.inspect}, only command hooks can be sequenced" unless hook.type == "command"
      reasons << "is async, async hooks cannot be sequenced" if hook.hook["async"] || hook.hook["asyncRewake"]
      reasons << "uses the powershell shell" if hook.hook["shell"] == "powershell"
      reasons << "has a matcher that does not compile" unless Matcher.valid?(hook.matcher)
      twins = twin_files(claude, hook)
      reasons << "has an identical handler on #{hook.event} in #{twins.join(', ')}" unless twins.empty?
      reasons << "is an ordonnateur dispatcher" if hook.dispatcher?
      if %w[user local].include?(hook.scope) && hook.plugin.nil? && Harnesses::ClaudeCode.managed_only?(claude[:sources])
        reasons << "managed settings set allowManagedHooksOnly, so Claude Code ignores user and local hooks"
      end
      reasons
    end

    def classify_claude(claude, unguarded, policy)
      mark_protected(claude[:hooks], policy)
      claude[:hooks].each do |hook|
        list = unguarded[hook.scope] || []
        reasons = refusal_reasons(claude, hook, list)
        hook.absorbable = reasons.empty?
        hook.reason = reasons.empty? ? nil : reasons.join("; ")
        hook.status =
          if hook.plugin && !hook.plugin_enabled then "disabled-plugin"
          elsif hook.dispatcher? then "dispatcher"
          elsif guard?(hook, list) then "guard"
          elsif hook.absorbable then "native"
          else "not-sequenceable"
          end
      end
      claude[:hooks]
    end

    def classify_hermes(hermes, policy)
      mark_protected(hermes[:hooks], policy)
      hermes[:hooks].each do |hook|
        reason = Harnesses::Hermes.pinned_reason(hook)
        hook.absorbable = reason.nil?
        hook.reason = reason
      end
      hermes[:hooks]
    end

    def antigravity_refusal(hook, files)
      return "is a plugin hook; plugin files are read-only" if hook.plugin
      return "is in a disabled plugin" if hook.status == "disabled-plugin"

      if hook.status == "file-skipped"
        entry = files.find { |file| file[:path] == hook.source_file }
        return "is in a file Antigravity skips whole: #{entry && entry[:error]}"
      end
      return "is on #{hook.event}, which Antigravity ignores" if hook.status == "ignored-event"
      return "is in the disabled hook spec #{hook.hook_name.inspect}" if hook.status == "disabled"
      return "is a prompt hook; ordonnateur orders command hooks" if hook.status == "prompt"

      Harnesses::Antigravity.pinned_reason(hook)&.then { |reason| "#{reason}; pinned hooks keep their place" }
    end

    def classify_antigravity(antigravity, policy)
      mark_protected(antigravity[:hooks], policy)
      antigravity[:hooks].each do |hook|
        reason = antigravity_refusal(hook, antigravity[:files])
        hook.absorbable = reason.nil?
        hook.reason = reason
      end
      antigravity[:hooks]
    end

    def describe(hook)
      "#{hook.id}  #{hook.command.to_s[0, 60]}"
    end

    def resolve(hooks, ref)
      exact = hooks.select { |hook| hook.id == ref }
      return single(exact, ref) unless exact.empty?

      if ref.match?(/\A\h{8}\z/)
        suffix = hooks.select { |hook| hook.short == ref }
        return single(suffix, ref) unless suffix.empty?
      end

      text = hooks.select { |hook| ([hook.command] + Array(hook.args)).compact.join(" ").include?(ref) }
      raise Usage, "no hook matches #{ref.inspect}" if text.empty?

      single(text, ref)
    end

    def single(matches, ref)
      return matches.first if matches.length == 1

      lines = matches.map { |hook| "  #{describe(hook)}" }
      raise Usage, "#{ref.inspect} is ambiguous; candidates:\n#{lines.join("\n")}"
    end
  end
end
