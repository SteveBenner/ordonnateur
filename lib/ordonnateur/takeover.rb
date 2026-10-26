#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "fileutils"
require "json"
require "open3"
require "shellwords"
require "tmpdir"

require_relative "model"
require_relative "card"
require_relative "inventory"
require_relative "harnesses/claude_code"

module Ordonnateur
  class Takeover
    Plan = Struct.new(
      :scope, :settings_path, :card_path, :settings_text_before, :settings_text_after, :card_text_before,
      :card_text_after, :settings_sha, :settings_mode, :card_before, :card_after, :verdicts, :refusals,
      :notes, keyword_init: true
    )

    attr_reader :scope, :root, :settings_path, :card_path

    def initialize(scope:, project: nil, ports:, cwd: Dir.pwd, via: "cli", at: nil)
      raise Usage, "scope must be user or local" unless %w[user local].include?(scope)

      @scope = scope
      @ports = ports
      @cwd = cwd
      @via = via
      @at = at
      @root = Harnesses::ClaudeCode.project_root(project)
      @settings_path = Harnesses::ClaudeCode.settings_path(scope, @root)
      @card_path = Harnesses::ClaudeCode.card_path(scope, @root)
      source = Harnesses::ClaudeCode.read_source(scope, @settings_path)
      @settings_text = source.text
      @settings_before = source.data
      @settings = Card.deep_copy(source.data)
      @hooks_key_present = @settings.key?("hooks")
      raise Refused, "#{@settings_path}: hooks is not an object" if @hooks_key_present && !@settings["hooks"].is_a?(Hash)

      load_card
      @inventory = Inventory.load(
        harness: "claude-code", project: @root, unguarded: Card.unguarded_map(@root), policy: @ports.policy
      )
      @refusals = []
      @notes = []
    end

    def load_card
      @card_before = Card.load_if_present(@card_path)
      @card_text_before = File.file?(@card_path) ? File.read(@card_path) : nil
      @card = @card_before ? Card.deep_copy(@card_before) : Card.blank(@scope, @settings_path)
      @card["settings_file"] = @settings_path
    rescue Card::Invalid => e
      raise Refused, "#{e.message}; run `ordonnateur lint`"
    end

    def candidates(event)
      own = Card.member_hooks(@card, @scope, @card_path)
      other_scope = @scope == "user" ? "local" : "user"
      other_path = Harnesses::ClaudeCode.card_path(other_scope, @root)
      other_card = begin
        Card.load_if_present(other_path)
      rescue Card::Invalid
        nil
      end
      others = Card.member_hooks(other_card, other_scope, other_path)
      settings = @inventory.hooks.select { |hook| hook.harness == "claude-code" }
      (settings + own + others).select { |hook| event.nil? || hook.event == event }
    end

    def own_member?(hook)
      hook.status.to_s.start_with?("member#") && hook.scope == @scope
    end

    def check_event!(event)
      raise Usage, "unknown Claude Code event #{event.inspect}" unless Model::CLAUDE_EVENTS.include?(event)
      return if Model::SEQUENCEABLE_EVENTS.include?(event)

      raise Refused, "event #{event} cannot be sequenced: #{Model.refused_reason(event)}"
    end

    def refusal_for(hook)
      return nil if own_member?(hook)

      if hook.status.to_s.start_with?("member#")
        return "#{Inventory.describe(hook)}: is a member of the #{hook.scope} card"
      end

      reasons = []
      if %w[user local].include?(hook.scope) && hook.plugin.nil?
        reasons << "is in the #{hook.scope} settings, not the #{@scope} settings of this change" if hook.scope != @scope
        reasons << hook.reason if hook.reason
      else
        reasons << (hook.reason || "is not in the user or local settings file")
      end
      reasons.empty? ? nil : "#{Inventory.describe(hook)}: #{reasons.join('; ')}"
    end

    def stop_on_block_for(event, flag)
      return flag unless flag.nil?

      entry = @card["events"][event]
      entry ? entry["stop_on_block"] : false
    end

    def plan_order(event, refs, stop_on_block: nil)
      check_event!(event)
      raise Usage, "order needs at least one hook; use release to empty an event" if refs.empty?

      pool = candidates(event)
      resolved = refs.map { |ref| Inventory.resolve(pool, ref) }
      resolved.group_by(&:id).each { |id, list| @refusals << "#{id}: listed more than once" if list.length > 1 }
      resolved.each { |hook| (message = refusal_for(hook)) && @refusals << message }
      raise Refused, refusal_text unless @refusals.empty?

      current = Card.members(@card, event)
      captured = resolved.reject { |hook| own_member?(hook) }.to_h { |hook| [hook.id, handler_ref(hook)] }
      new_members = resolved.uniq(&:id).map do |hook|
        existing = current.find { |member| member["id"] == hook.id }
        existing || Card.member_for(hook, at: @at || Time.now.utc)
      end
      released = current.reject { |member| new_members.any? { |kept| kept["id"] == member["id"] } }
      absorb(captured)
      released.each { |member| release_member(event, member) }
      flag = stop_on_block_for(event, stop_on_block)
      @card["events"][event] = { "stop_on_block" => flag, "members" => new_members }
      sync_dispatcher(event)
      finish
    end

    def plan_move(event, ref, mode, other_ref = nil)
      check_event!(event)
      members = Card.members(@card, event)
      raise Refused, "no card members on #{event} in the #{@scope} card" if members.empty?

      pool = Card.member_hooks(@card, @scope, @card_path).select { |hook| hook.event == event }
      target = Inventory.resolve(pool, ref)
      item = members.find { |member| member["id"] == target.id }
      rest = members.reject { |member| member.equal?(item) }
      ordered =
        case mode
        when :first then [item] + rest
        when :last then rest + [item]
        when :before, :after
          anchor = Inventory.resolve(pool, other_ref)
          raise Refused, "#{target.id} cannot be moved relative to itself" if anchor.id == target.id

          index = rest.index { |member| member["id"] == anchor.id }
          rest.insert(mode == :before ? index : index + 1, item)
        else
          raise Usage, "move needs --first, --last, --before or --after"
        end
      @card["events"][event]["members"] = ordered
      sync_dispatcher(event)
      finish
    end

    def plan_release(event)
      events = event ? [event] : @card["events"].keys
      if event
        check_event!(event)
        raise Refused, "no card members on #{event} in the #{@scope} card" if Card.members(@card, event).empty?
      end
      events.each do |name|
        Card.members(@card, name).dup.each { |member| release_member(name, member) }
        @card["events"].delete(name)
        sync_dispatcher(name)
      end
      @notes << "nothing to release" if events.empty?
      finish
    end

    def plan_unguard(ref)
      pool = @inventory.hooks.select { |hook| hook.harness == "claude-code" && hook.scope == @scope && hook.plugin.nil? }
      hook = Inventory.resolve(pool, ref)
      if Inventory.hard_guard?(hook)
        raise Refused, "#{Inventory.describe(hook)}: is a guard that cannot be unguarded (#{hook.policy_reason || 'onFailure is block'})"
      end
      unless Model::GUARD_EVENTS.include?(hook.event)
        raise Refused, "#{Inventory.describe(hook)}: is not a guard; event #{hook.event} has no guard rule"
      end
      if @card["unguarded"].include?(hook.digest)
        @notes << "#{hook.id} is already unguarded"
      else
        @card["unguarded"] << hook.digest
      end
      finish
    end

    def plan_guard(ref)
      pool = @inventory.hooks.select { |hook| hook.harness == "claude-code" && hook.scope == @scope && hook.plugin.nil? }
      pool += Card.member_hooks(@card, @scope, @card_path)
      hook = Inventory.resolve(pool, ref)
      member = own_member?(hook)
      listed = @card["unguarded"].include?(hook.digest)
      unless member || listed
        @notes << "#{hook.id} is already a guard or needs no change"
        return finish
      end
      @card["unguarded"].delete(hook.digest)
      if member
        item = Card.members(@card, hook.event).find { |entry| entry["id"] == hook.id }
        release_member(hook.event, item)
        sync_dispatcher(hook.event)
      end
      finish
    end

    def handler_ref(hook)
      groups = @settings.dig("hooks", hook.event)
      group = groups.is_a?(Array) ? groups[hook.group_index] : nil
      handler = group.is_a?(Hash) && group["hooks"].is_a?(Array) ? group["hooks"][hook.handler_index] : nil
      unless handler && Canonical.json(handler) == Canonical.json(hook.hook)
        raise SettingsChanged, "settings changed while planning; run again"
      end

      { event: hook.event, group: group, handler: handler }
    end

    def absorb(captured)
      touched = Hash.new { |h, k| h[k] = [] }
      captured.each_value do |ref|
        ref[:group]["hooks"].delete_if { |handler| handler.equal?(ref[:handler]) }
        touched[ref[:event]] << ref[:group]
      end
      touched.each do |event, groups|
        list = @settings["hooks"][event]
        list.delete_if { |group| group["hooks"].empty? && groups.any? { |touched_group| touched_group.equal?(group) } }
        @settings["hooks"].delete(event) if list.empty?
      end
    end

    def release_member(event, member)
      group = {}
      group["matcher"] = member["matcher"] unless member["matcher"].nil?
      group["hooks"] = [Card.deep_copy(member["hook"])]
      @settings["hooks"] ||= {}
      (@settings["hooks"][event] ||= []) << group
      @card["events"][event]["members"].delete_if { |entry| entry.equal?(member) } if @card["events"][event]
    end

    def self.quote_path(path)
      home = ENV["HOME"].to_s
      if !home.empty? && (path == home || path.start_with?("#{home}/"))
        rest = path[home.length..]
        %("$HOME#{rest.gsub(/(["\\$`])/) { "\\#{Regexp.last_match(1)}" }}")
      else
        "'#{path.gsub("'", %q('\\\\''))}'"
      end
    end

    def dispatcher_command(event)
      binary = File.join(Rplugin::Paths.bin_home, "ordonnateur")
      "#{self.class.quote_path(binary)} run claude-code #{event} --card #{self.class.quote_path(@card_path)}"
    end

    def dispatcher_group?(group)
      return false unless group.is_a?(Hash) && group["hooks"].is_a?(Array) && group["hooks"].length == 1

      command = group["hooks"].first["command"]
      Model.dispatcher_command?(command) && Model.dispatcher_card_path(command) == @card_path
    end

    def sync_dispatcher(event)
      entry = @card["events"][event]
      members = entry ? entry["members"] : []
      list = @settings.dig("hooks", event)
      if members.empty?
        @card["events"].delete(event)
        return unless list.is_a?(Array)

        list.delete_if { |group| dispatcher_group?(group) }
        @settings["hooks"].delete(event) if list.empty?
        return
      end
      @settings["hooks"] ||= {}
      list = (@settings["hooks"][event] ||= [])
      group = {
        "hooks" => [{
          "type" => "command", "command" => dispatcher_command(event), "timeout" => Card.timeout_total(event, members)
        }]
      }
      index = list.index { |item| dispatcher_group?(item) }
      index ? list[index] = group : list << group
    end

    def finish
      @settings.delete("hooks") if @settings["hooks"].is_a?(Hash) && @settings["hooks"].empty? && !@hooks_key_present
      before_data = @settings_before
      text_after =
        if @settings == before_data
          @settings_text
        else
          json = JSON.pretty_generate(@settings)
          @settings_text.nil? || @settings_text.end_with?("\n") ? "#{json}\n" : json
        end
      blank = @card["events"].empty? && @card["unguarded"].empty?
      card_after_text = @card_before.nil? && blank ? nil : Card.dump(@card)
      card_after_text = @card_text_before if @card_before && Card.deep_copy(@card_before) == @card
      plan = Plan.new(
        scope: @scope, settings_path: @settings_path, card_path: @card_path,
        settings_text_before: @settings_text, settings_text_after: text_after,
        card_text_before: @card_text_before, card_text_after: card_after_text,
        settings_sha: Digest::SHA256.hexdigest(@settings_text.to_s),
        settings_mode: Harnesses::ClaudeCode.mode_of(@settings_path),
        card_before: @card_before, card_after: Card.deep_copy(@card), refusals: @refusals, notes: @notes
      )
      plan.verdicts = verdicts_for(plan)
      plan
    end

    def verdicts_for(plan)
      targets = []
      targets << [plan.settings_path, plan.settings_text_after] if plan.settings_text_after != plan.settings_text_before
      targets << [plan.card_path, plan.card_text_after] if plan.card_text_after != plan.card_text_before
      targets.map do |path, content|
        verdict = @ports.policy.judge(
          tool_name: "Write", tool_input: { "file_path" => path, "content" => content.to_s }, cwd: @cwd
        )
        [path, verdict]
      end
    end

    def refusal_text
      (["refused:"] + @refusals.map { |line| "  #{line}" }).join("\n")
    end

    def render(plan)
      lines = []
      events = plan.card_after["events"]
      if events.empty?
        lines << "no events carded in the #{plan.scope} card"
      else
        events.each do |event, entry|
          lines << "#{event} (stop_on_block: #{entry['stop_on_block']})"
          entry["members"].each_with_index do |member, index|
            lines << "  #{index + 1}. #{member['id']}  #{member['hook']['command'].to_s[0, 60]}"
          end
        end
      end
      lines << "unguarded: #{plan.card_after['unguarded'].length} digest(s)" unless plan.card_after["unguarded"].empty?
      plan.notes.each { |note| lines << "note: #{note}" }
      plan.refusals.each { |refusal| lines << "refused: #{refusal}" }
      plan.verdicts.each do |path, verdict|
        lines << "policy: write #{path}: #{verdict[:verdict]}#{verdict[:rule_id] ? " (#{verdict[:rule_id]})" : ''} #{verdict[:reason]}".rstrip
      end
      lines << diff(plan.settings_path, plan.settings_text_before, plan.settings_text_after)
      lines << diff(plan.card_path, plan.card_text_before, plan.card_text_after)
      lines.reject { |line| line.nil? || line.empty? }.join("\n")
    end

    def changed?(plan)
      plan.settings_text_after != plan.settings_text_before || plan.card_text_after != plan.card_text_before
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
      current = Harnesses::ClaudeCode.read_text(plan.settings_path)
      unless Digest::SHA256.hexdigest(current.to_s) == plan.settings_sha
        raise SettingsChanged, "settings changed while planning; run again"
      end

      if plan.settings_text_after != plan.settings_text_before
        Harnesses::ClaudeCode.write_file(plan.settings_path, plan.settings_text_after, mode: plan.settings_mode || 0o600)
      end
      if plan.card_text_after != plan.card_text_before
        mode = Harnesses::ClaudeCode.mode_of(plan.card_path)
        Harnesses::ClaudeCode.write_file(plan.card_path, plan.card_text_after, mode: mode)
      end
      emit(plan)
      true
    end

    def backup(plan)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      dir = File.join(Rplugin::Paths.state_home, "ordonnateur", "backups")
      FileUtils.mkdir_p(dir)
      [plan.settings_path, plan.card_path].each do |path|
        next unless File.file?(path)

        target = File.join(dir, "#{stamp}-#{plan.scope}-#{File.basename(path)}")
        counter = 1
        while File.exist?(target)
          target = File.join(dir, "#{stamp}-#{plan.scope}-#{File.basename(path)}.#{counter}")
          counter += 1
        end
        FileUtils.cp(path, target, preserve: true)
      end
    end

    def emit(plan)
      before = plan.card_before ? plan.card_before["events"] : {}
      after = plan.card_after["events"]
      (before.keys | after.keys).each do |event|
        old = before[event]
        new = after[event]
        next if old == new

        ids = new ? new["members"].map { |member| member["id"] } : []
        @ports.events.emit(
          "ordonnateur.card.applied",
          { "harness" => "claude-code", "scope" => plan.scope, "event" => event, "members" => ids, "via" => @via }
        )
      end
    end
  end
end
