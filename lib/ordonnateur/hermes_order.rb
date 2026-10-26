#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "digest"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

require_relative "model"
require_relative "inventory"
require_relative "harnesses/hermes"

module Ordonnateur
  class HermesOrder
    Plan = Struct.new(
      :scope, :settings_path, :card_path, :settings_text_before, :settings_text_after, :card_text_before,
      :card_text_after, :settings_sha, :settings_mode, :card_before, :card_after, :verdicts, :refusals,
      :notes, :event, :before_ids, :after_ids, keyword_init: true
    )

    LAYOUT_REFUSAL = "config.yaml layout is not supported for an in-place reorder"
    RESTART_NOTE = "Hermes applies this order to new processes; a running gateway keeps its current order until restart."

    attr_reader :scope, :settings_path

    def initialize(project: nil, ports:, cwd: Dir.pwd, via: "cli", at: nil)
      @ports = ports
      @cwd = cwd
      @via = via
      @at = at
      @scope = "user"
      @inventory = Inventory.load(harness: "hermes", project: project, policy: ports.policy)
      loaded = @inventory.hermes
      @settings_path = loaded[:config_path]
      @text = loaded[:text]
      @data = loaded[:data]
      @hooks = @inventory.hooks.select { |hook| hook.harness == "hermes" }
      @refusals = []
      @notes = []
    end

    def check_event!(event)
      if Model::HERMES_PYTHON_ONLY_EVENTS.include?(event)
        raise Refused, "event #{event} is Python-plugin-only; Hermes refuses shell hooks on it"
      end
      return if Model::HERMES_EVENTS.include?(event)

      raise Usage, "unknown Hermes event #{event.inspect}"
    end

    def event_hooks(event)
      @hooks.select { |hook| hook.event == event }
    end

    def event_list(event)
      list = @data.dig("hooks", event)
      list.is_a?(Array) ? list : []
    end

    def pinned_reason(hook)
      reason = Harnesses::Hermes.pinned_reason(hook)
      reason && "#{Inventory.describe(hook)}: #{reason}; pinned hooks keep their place"
    end

    def fail!
      raise Refused, refusal_text
    end

    def plan_order(event, refs)
      check_event!(event)
      raise Refused, "order needs at least two hooks of one event" if refs.length < 2

      resolved = refs.map { |ref| Inventory.resolve(@hooks, ref) }
      resolved.group_by(&:id).each { |id, list| @refusals << "#{id}: listed more than once" if list.length > 1 }
      resolved.each do |hook|
        if hook.event != event
          @refusals << "#{Inventory.describe(hook)}: is on #{hook.event}, not #{event}"
        elsif (message = pinned_reason(hook))
          @refusals << message
        end
      end
      fail! unless @refusals.empty?

      slots = resolved.map(&:group_index).sort
      permutation = (0...event_list(event).length).to_a
      slots.each_with_index { |slot, position| permutation[slot] = resolved[position].group_index }
      finish(event, permutation)
    end

    def plan_move(event, ref, mode, other_ref = nil)
      check_event!(event)
      pool = event_hooks(event)
      raise Refused, "no Hermes hooks on #{event}" if pool.empty?

      target = Inventory.resolve(pool, ref)
      if (message = pinned_reason(target))
        @refusals << message
        fail!
      end
      movable = pool.reject { |hook| Harnesses::Hermes.pinned?(hook) }
      raise Refused, "#{target.id}: no other unpinned hook on #{event} to move relative to" if movable.length < 2

      rest = movable.reject { |hook| hook.group_index == target.group_index }
      ordered =
        case mode
        when :first then [target] + rest
        when :last then rest + [target]
        when :before, :after
          anchor = Inventory.resolve(pool, other_ref)
          raise Refused, "#{target.id} cannot be moved relative to itself" if anchor.group_index == target.group_index

          if (message = pinned_reason(anchor))
            @refusals << message
            fail!
          end
          index = rest.index { |hook| hook.group_index == anchor.group_index }
          rest.dup.insert(mode == :before ? index : index + 1, target)
        else
          raise Usage, "move needs --first, --last, --before or --after"
        end
      permutation = (0...event_list(event).length).to_a
      movable.map(&:group_index).sort.each_with_index { |slot, position| permutation[slot] = ordered[position].group_index }
      finish(event, permutation)
    end

    def rewrite(event, permutation)
      layout, reason = Harnesses::Hermes.event_layout(@text, event)
      unless layout
        @refusals << "#{LAYOUT_REFUSAL} (#{reason})"
        fail!
      end
      list = event_list(event)
      if layout[:ranges].length != list.length
        @refusals << "#{LAYOUT_REFUSAL} (item count differs from the parsed list)"
        fail!
      end
      lines = layout[:lines]
      first = layout[:ranges].first[0]
      last = layout[:ranges].last[1]
      blocks = layout[:ranges].map { |from, to| lines[from...to].join }
      ends_newline = blocks.last.end_with?("\n")
      moved = permutation.map { |index| blocks[index].end_with?("\n") ? blocks[index] : "#{blocks[index]}\n" }
      moved[-1] = moved[-1].chomp unless ends_newline
      after = lines[0...first].join + moved.join + lines[last..].join
      prove!(event, permutation, after)
      after
    end

    def prove!(event, permutation, after)
      before = YAML.safe_load(@text, aliases: false)
      expected = Marshal.load(Marshal.dump(before))
      expected["hooks"][event] = permutation.map { |index| before["hooks"][event][index] }
      actual = YAML.safe_load(after, aliases: false)
      return if actual == expected

      @refusals << LAYOUT_REFUSAL
      fail!
    rescue Psych::Exception, NoMethodError, TypeError
      @refusals << LAYOUT_REFUSAL
      fail!
    end

    def finish(event, permutation)
      before_hooks = event_hooks(event)
      identity = permutation == (0...permutation.length).to_a
      after_text = identity ? @text : rewrite(event, permutation)
      by_index = before_hooks.to_h { |hook| [hook.group_index, hook] }
      before_ids = before_hooks.map(&:id)
      after_ids = permutation.map { |index| by_index[index]&.id }.compact
      @notes << "nothing to reorder" if identity
      unless identity
        @notes << RESTART_NOTE
        permutation.each_with_index do |old, position|
          next if old == position

          hook = by_index[old]
          @notes << "#{hook.id} is not allowlisted, so Hermes does not run it" if hook && hook.status == "not-allowlisted"
        end
      end
      plan = Plan.new(
        scope: @scope, settings_path: @settings_path, card_path: nil, settings_text_before: @text,
        settings_text_after: after_text, card_text_before: nil, card_text_after: nil,
        settings_sha: Digest::SHA256.hexdigest(@text.to_s), settings_mode: Harnesses::Hermes.mode_of(@settings_path),
        card_before: nil, card_after: nil, refusals: @refusals, notes: @notes, event: event,
        before_ids: before_ids, after_ids: after_ids
      )
      plan.verdicts = verdicts_for(plan)
      plan
    end

    def verdicts_for(plan)
      return [] if plan.settings_text_after == plan.settings_text_before

      verdict = @ports.policy.judge(
        tool_name: "Write",
        tool_input: { "file_path" => plan.settings_path, "content" => plan.settings_text_after.to_s },
        cwd: @cwd
      )
      [[plan.settings_path, verdict]]
    end

    def refusal_text
      (["refused:"] + @refusals.map { |line| "  #{line}" }).join("\n")
    end

    def render(plan)
      lines = []
      lines << plan.event.to_s
      by_id = @hooks.to_h { |hook| [hook.id, hook] }
      plan.after_ids.each_with_index do |id, index|
        lines << "  #{index + 1}. #{id}  #{by_id[id]&.command.to_s[0, 60]}"
      end
      plan.notes.each { |note| lines << "note: #{note}" }
      plan.refusals.each { |refusal| lines << "refused: #{refusal}" }
      plan.verdicts.each do |path, verdict|
        lines << "policy: write #{path}: #{verdict[:verdict]}#{verdict[:rule_id] ? " (#{verdict[:rule_id]})" : ''} #{verdict[:reason]}".rstrip
      end
      lines << diff(plan.settings_path, plan.settings_text_before, plan.settings_text_after)
      lines.reject { |line| line.nil? || line.empty? }.join("\n")
    end

    def changed?(plan)
      plan.settings_text_after != plan.settings_text_before
    end

    def diff(path, before, after)
      return nil if before.to_s == after.to_s

      Dir.mktmpdir("ordonnateur-diff") do |dir|
        left = File.join(dir, "before")
        right = File.join(dir, "after")
        File.write(left, before.to_s)
        File.write(right, after.to_s)
        out, _status = Open3.capture2("diff", "-u", "--label", path, "--label", path, left, right)
        out.chomp
      end
    end

    def apply(plan)
      return false unless changed?(plan)

      plan.verdicts.each do |path, verdict|
        case verdict[:verdict]
        when "deny"
          raise Refused, "polispec denies writing #{path}: #{verdict[:reason]} (#{verdict[:rule_id]})"
        when "warn"
          raise Refused, "polispec warns on writing #{path}: #{verdict[:reason]}; ask the user, then the user runs this command; ordonnateur never proceeds on a warn"
        end
      end
      backup(plan)
      current = Harnesses::Hermes.read_text(plan.settings_path)
      unless Digest::SHA256.hexdigest(current.to_s) == plan.settings_sha
        raise SettingsChanged, "settings changed while planning; run again"
      end

      Rplugin::AtomicFile.write(plan.settings_path, plan.settings_text_after, mode: plan.settings_mode || 0o600)
      emit(plan)
      true
    end

    def backup(plan)
      return unless File.file?(plan.settings_path)

      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      dir = File.join(Rplugin::Paths.state_home, "ordonnateur", "backups")
      FileUtils.mkdir_p(dir)
      base = File.join(dir, "#{stamp}-#{plan.scope}-#{File.basename(plan.settings_path)}")
      target = base
      counter = 1
      while File.exist?(target)
        target = "#{base}.#{counter}"
        counter += 1
      end
      FileUtils.cp(plan.settings_path, target, preserve: true)
    end

    def emit(plan)
      @ports.events.emit(
        "ordonnateur.card.applied",
        {
          "harness" => "hermes", "scope" => plan.scope, "event" => plan.event, "members" => plan.after_ids,
          "via" => @via
        }
      )
    end
  end
end
