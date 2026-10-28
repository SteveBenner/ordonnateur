#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

require_relative "model"
require_relative "canonical"
require_relative "inventory"
require_relative "harnesses/antigravity"

module Ordonnateur
  class AntigravityOrder
    Plan = Struct.new(
      :scope, :settings_path, :card_path, :settings_text_before, :settings_text_after, :card_text_before,
      :card_text_after, :settings_sha, :settings_mode, :card_before, :card_after, :verdicts, :refusals,
      :notes, :event, :before_ids, :after_ids, :mode, :released_events, keyword_init: true
    )

    SESSION_NOTE = "Antigravity reads hooks when a session starts; running sessions may keep the order they loaded."
    REWRITE_REFUSAL = "hooks.json could not be rewritten exactly"
    SPEC = Model::ANTIGRAVITY_MEMBER_SPEC
    ENABLED = %w[active member].freeze

    attr_reader :scope

    def initialize(scope:, project: nil, ports:, cwd: Dir.pwd, via: "cli", at: nil, file: nil)
      raise Usage, "scope must be global or workspace" unless %w[global workspace].include?(scope)
      raise Usage, "workspace scope needs a project" if scope == "workspace" && project.nil?

      @scope = scope
      @ports = ports
      @cwd = cwd
      @via = via
      @at = at
      @file = file
      @inventory = Inventory.load(harness: "antigravity", project: project, policy: ports.policy)
      @loaded = @inventory.antigravity
      @hooks = @inventory.hooks.select { |hook| hook.harness == "antigravity" }
      @refusals = []
      @notes = []
      @path = nil
    end

    def settings_path
      @path || (@scope == "global" ? Harnesses::Antigravity.global_path : nil)
    end

    def fail!
      raise Refused, refusal_text
    end

    def refusal_text
      (["refused:"] + @refusals.map { |line| "  #{line}" }).join("\n")
    end

    def check_event!(event)
      return if Model::ANTIGRAVITY_EVENTS.include?(event)

      raise Usage, "unknown Antigravity event #{event.inspect}"
    end

    def tool?(event)
      Model::ANTIGRAVITY_TOOL_EVENTS.include?(event)
    end

    def copy(value)
      Harnesses::Antigravity.plain(value)
    end

    def prepare(path)
      @path = path
      entry = @loaded[:files].find { |item| item[:path] == path }
      if entry
        if entry[:error]
          @refusals << "fix #{path} first: #{entry[:error]}"
          fail!
        end
        @text = entry[:text]
        @data = copy(entry[:data])
      else
        @text = nil
        @data = {}
      end
      @original = copy(@data)
      @ledger_path = Harnesses::Antigravity.ledger_path(@scope, path)
      @ledger_text = Harnesses::Antigravity.read_text(@ledger_path)
      @ledger = @loaded[:ledgers][path]
      if @data.key?(SPEC) && (@ledger.nil? || @ledger["events"].empty?)
        @refusals << "#{path} already has a hook named ordonnateur that ordonnateur did not write"
        fail!
      end
      if @data[SPEC].is_a?(Hash) && @data[SPEC]["enabled"] == false
        @refusals << "#{path}: the ordonnateur hook spec is disabled"
        fail!
      end
      @work = @ledger ? copy(@ledger) : Harnesses::Antigravity.blank_ledger(path)
      @file_hooks = @hooks.select { |hook| hook.source_file == path }
    end

    def eligibility(hooks, event = nil)
      hooks.group_by(&:id).each { |id, list| @refusals << "#{id}: listed more than once" if list.length > 1 }
      hooks.each do |hook|
        if hook.plugin
          @refusals << "#{hook.id}: plugin hooks are read-only"
        elsif event && hook.event != event
          @refusals << "#{Inventory.describe(hook)}: is on #{hook.event}, not #{event}"
        elsif hook.scope != @scope
          @refusals << "#{Inventory.describe(hook)}: is in the #{hook.scope} hooks, not the #{@scope} hooks of this change"
        elsif !hook.absorbable
          @refusals << "#{Inventory.describe(hook)}: #{hook.reason}"
        end
      end
      files = hooks.map(&:source_file).uniq
      @refusals << "hooks of different files cannot be ordered together" if files.length > 1
      fail! unless @refusals.empty?
    end

    def members_of(event)
      @file_hooks.select { |hook| hook.hook_name == SPEC && hook.event == event && Harnesses::Antigravity.member?(hook) }
                 .sort_by(&:member_position)
    end

    def hook_at(name, event, group_index, handler_index)
      @file_hooks.find do |hook|
        hook.hook_name == name && hook.event == event && hook.group_index == group_index &&
          hook.handler_index == handler_index
      end
    end

    def sequence(list, tool)
      seq = []
      list.each_with_index do |entry, group_index|
        if tool
          handlers = entry.is_a?(Hash) && entry["hooks"].is_a?(Array) ? entry["hooks"] : []
          if handlers.empty?
            seq << { inert: entry }
          else
            handlers.each_with_index do |handler, handler_index|
              seq << { gi: group_index, hi: handler_index, group: entry, handler: handler }
            end
          end
        else
          seq << { gi: group_index, hi: 0, handler: entry }
        end
      end
      seq
    end

    def group_of(run)
      run[:group].each_with_object({}) do |(key, value), out|
        out[key] = key == "hooks" ? run[:handlers] : value
      end
    end

    def rebuild(seq, tool)
      return seq.map { |item| item[:handler] } unless tool

      out = []
      run = nil
      flush = lambda do
        out << group_of(run) if run
        run = nil
      end
      seq.each do |item|
        if item[:inert]
          flush.call
          out << item[:inert]
        elsif run && run[:gi] == item[:gi]
          run[:handlers] << item[:handler]
        else
          flush.call
          run = { gi: item[:gi], group: item[:group], handlers: [item[:handler]] }
        end
      end
      flush.call
      out
    end

    def unit_index(seq, hook, tool)
      index = seq.index do |item|
        !item[:inert] && item[:gi] == hook.group_index && (!tool || item[:hi] == hook.handler_index)
      end
      unless index && Canonical.json(seq[index][:handler]) == Canonical.json(hook.hook)
        raise SettingsChanged, "settings changed while planning; run again"
      end

      index
    end

    def permute(name, event, ordered)
      tool = tool?(event)
      spec = @data[name]
      seq = sequence(spec[event], tool)
      positions = ordered.map { |hook| unit_index(seq, hook, tool) }
      moved = seq.dup
      positions.sort.each_with_index { |slot, k| moved[slot] = seq[positions[k]] }
      spec[event] = rebuild(moved, tool)
      moved.reject { |item| item[:inert] }.filter_map { |item| hook_at(name, event, item[:gi], item[:hi])&.id }
    end

    def spec_hooks(name, event)
      @file_hooks.select { |hook| hook.hook_name == name && hook.event == event }
                 .sort_by { |hook| [hook.group_index, hook.handler_index] }
    end

    def plan_order(event, refs)
      check_event!(event)
      raise Refused, "order needs at least two hooks of one event" if refs.length < 2

      resolved = refs.map { |ref| Inventory.resolve(@hooks, ref) }
      eligibility(resolved, event)
      prepare(resolved.first.source_file)
      names = resolved.map(&:hook_name).uniq
      if names.length == 1 && names.first != SPEC && members_of(event).empty?
        in_place(event, names.first, resolved)
      else
        member_mode(event, resolved)
      end
    end

    def in_place(event, name, ordered)
      before = spec_hooks(name, event).map(&:id)
      after = permute(name, event, ordered)
      finish(event, "in_place", before, after)
    end

    def ordered_with(list, target, mode, anchor)
      rest = list.reject { |hook| hook.equal?(target) }
      case mode
      when :first then [target] + rest
      when :last then rest + [target]
      when :before, :after
        index = rest.index { |hook| hook.equal?(anchor) }
        rest.dup.insert(mode == :before ? index : index + 1, target)
      else
        raise Usage, "move needs --first, --last, --before or --after"
      end
    end

    def plan_move(event, ref, mode, other_ref = nil)
      check_event!(event)
      raise Usage, "move needs --first, --last, --before or --after" unless %i[first last before after].include?(mode)

      pool = @hooks.select { |hook| hook.event == event }
      raise Refused, "no Antigravity hooks on #{event}" if pool.empty?

      target = Inventory.resolve(pool, ref)
      anchor = nil
      if %i[before after].include?(mode)
        anchor = Inventory.resolve(pool, other_ref)
        raise Refused, "#{target.id} cannot be moved relative to itself" if anchor.equal?(target)
      end
      eligibility([target, anchor].compact, event)
      prepare(target.source_file)
      members = members_of(event)
      if Harnesses::Antigravity.member?(target)
        if anchor && !Harnesses::Antigravity.member?(anchor)
          @refusals << "#{target.id}: a member can only be moved next to another member"
          fail!
        end
        member_mode(event, ordered_with(members, target, mode, anchor))
      elsif anchor && Harnesses::Antigravity.member?(anchor)
        member_mode(event, ordered_with(members, target, mode, anchor))
      else
        if anchor && anchor.hook_name != target.hook_name
          @refusals << "#{target.id} and #{anchor.id} are in different hook specs; use order to sequence them"
          fail!
        end
        movable = spec_hooks(target.hook_name, event).select { |hook| hook.absorbable }
        if movable.length < 2
          raise Refused, "#{target.id}: no other unpinned hook on #{event} in the hook spec #{target.hook_name} to move relative to"
        end

        in_place(event, target.hook_name, ordered_with(movable, target, mode, anchor))
      end
    end

    def resolve_unit(hook)
      spec = @data[hook.hook_name]
      list = spec.is_a?(Hash) ? spec[hook.event] : nil
      raise SettingsChanged, "settings changed while planning; run again" unless list.is_a?(Array)

      if tool?(hook.event)
        group = list[hook.group_index]
        handler = group.is_a?(Hash) && group["hooks"].is_a?(Array) ? group["hooks"][hook.handler_index] : nil
      else
        group = nil
        handler = list[hook.group_index]
      end
      unless handler && Canonical.json(handler) == Canonical.json(hook.hook)
        raise SettingsChanged, "settings changed while planning; run again"
      end

      { hook: hook, spec: spec, list: list, group: group, handler: handler }
    end

    def ledger_entry(hook, event)
      return origin_entry(hook) unless Harnesses::Antigravity.member?(hook)

      entries = Array(@work["events"][event])
      candidate = entries[hook.member_position]
      return candidate if candidate && candidate["digest"] == hook.digest

      entries.find { |entry| entry["digest"] == hook.digest }
    end

    def origin_entry(hook)
      {
        "digest" => hook.digest,
        "origin" => {
          "hook_name" => hook.hook_name, "group_index" => hook.group_index, "handler_index" => hook.handler_index,
          "matcher" => hook.matcher
        }
      }
    end

    def detach(units)
      touched = []
      units.each do |unit|
        if unit[:group]
          unit[:group]["hooks"].delete_if { |item| item.equal?(unit[:handler]) }
        else
          unit[:list].delete_if { |item| item.equal?(unit[:handler]) }
        end
        touched << unit
      end
      touched.each do |unit|
        next unless unit[:group] && unit[:group]["hooks"].empty?

        unit[:list].delete_if { |group| group.equal?(unit[:group]) }
      end
      touched.each do |unit|
        name = unit[:hook].hook_name
        spec = @data[name]
        next unless spec.is_a?(Hash)

        spec.delete(unit[:hook].event) if spec[unit[:hook].event].is_a?(Array) && spec[unit[:hook].event].empty?
        @data.delete(name) if spec.empty?
      end
    end

    def origin_key(entry)
      origin = entry["origin"]
      [origin["hook_name"], origin["group_index"], origin["handler_index"]]
    end

    def reinsert(entry, event, handler)
      origin = entry["origin"]
      spec = (@data[origin["hook_name"]] ||= {})
      insert_into((spec[event] ||= []), event, origin, handler)
    end

    def virtual_origin(hook, event, current, entries, units)
      name = hook.hook_name
      tool = tool?(event)
      virtual = @data[name][event].map do |item|
        tool && item.is_a?(Hash) && item["hooks"].is_a?(Array) ? item.merge("hooks" => item["hooks"].dup) : item
      end
      earlier = current.select { |member| entries[member]["origin"]["hook_name"] == name }
      earlier.sort_by { |member| origin_key(entries[member]) }.each do |member|
        insert_into(virtual, event, entries[member]["origin"], units[member][:handler])
      end
      handler = units[hook][:handler]
      return [virtual.index { |item| item.equal?(handler) }, 0] unless tool

      group = virtual.index do |item|
        item.is_a?(Hash) && item["hooks"].is_a?(Array) && item["hooks"].any? { |inner| inner.equal?(handler) }
      end
      [group, virtual[group]["hooks"].index { |inner| inner.equal?(handler) }]
    end

    def insert_into(list, event, origin, handler)
      if tool?(event)
        group = list[origin["group_index"]]
        if group.is_a?(Hash) && group["hooks"].is_a?(Array) && group["matcher"] == origin["matcher"] &&
           origin["handler_index"] <= group["hooks"].length
          group["hooks"].insert(origin["handler_index"], handler)
        else
          fresh = {}
          fresh["matcher"] = origin["matcher"] unless origin["matcher"].nil?
          fresh["hooks"] = [handler]
          list.insert([origin["group_index"], list.length].min, fresh)
        end
      elsif origin["group_index"] <= list.length
        list.insert(origin["group_index"], handler)
      else
        list << handler
      end
    end

    def member_mode(event, named)
      current = members_of(event)
      released = current.reject { |hook| named.any? { |item| item.equal?(hook) } }
      released.each do |hook|
        @refusals << "#{Inventory.describe(hook)}: #{Harnesses::Antigravity.pinned_reason(hook)}; pinned hooks keep their place" if Harnesses::Antigravity.pinned?(hook)
      end
      fail! unless @refusals.empty?

      entries = {}
      (named + released).each do |hook|
        entry = ledger_entry(hook, event)
        if entry
          entries[hook] = entry
        else
          @refusals << "#{hook.id}: ordonnateur has no record of where this hook came from"
        end
      end
      fail! unless @refusals.empty?

      before = (@file_hooks.select { |hook| hook.event == event && (named + current).any? { |item| item.equal?(hook) } }).map(&:id)
      units = (named + released).to_h { |hook| [hook, resolve_unit(hook)] }
      named.reject { |hook| Harnesses::Antigravity.member?(hook) }.each do |hook|
        group, index = virtual_origin(hook, event, current, entries, units)
        entries[hook]["origin"]["group_index"] = group
        entries[hook]["origin"]["handler_index"] = index
      end
      detach(named.reject { |hook| Harnesses::Antigravity.member?(hook) }.map { |hook| units[hook] })
      spec = (@data[SPEC] ||= {})
      spec[event] = named.map do |hook|
        handler = units[hook][:handler]
        next handler unless tool?(event)

        group = {}
        group["matcher"] = hook.matcher unless hook.matcher.nil?
        group["hooks"] = [handler]
        group
      end
      released.sort_by { |hook| origin_key(entries[hook]) }.each { |hook| reinsert(entries[hook], event, units[hook][:handler]) }
      @work["events"][event] = named.map { |hook| entries[hook] }
      leftovers = @hooks.select do |hook|
        hook.event == event && ENABLED.include?(hook.status) && named.none? { |item| item.equal?(hook) }
      end
      finish(event, "members", before, named.map(&:id), leftovers: leftovers)
    end

    def plan_release(event)
      check_event!(event) if event
      path = release_file(event)
      prepare(path)
      events = event ? [event] : (@data[SPEC].is_a?(Hash) ? @data[SPEC].keys.select { |key| @data[SPEC][key].is_a?(Array) } : [])
      before = []
      events.each do |name|
        members = members_of(name)
        raise Refused, "no ordonnateur members on #{name} in the #{@scope} hooks" if members.empty? && event

        before.concat(members.map(&:id))
        entries = members.to_h { |hook| [hook, ledger_entry(hook, name)] }
        entries.each { |hook, entry| @refusals << "#{hook.id}: ordonnateur has no record of where this hook came from" unless entry }
        fail! unless @refusals.empty?

        members.each do |hook|
          if Harnesses::Antigravity.pinned?(hook)
            @refusals << "#{Inventory.describe(hook)}: #{Harnesses::Antigravity.pinned_reason(hook)}; pinned hooks keep their place"
          end
        end
        fail! unless @refusals.empty?

        handlers = members.to_h { |hook| [hook, resolve_unit(hook)[:handler]] }
        @data[SPEC].delete(name)
        members.sort_by { |hook| origin_key(entries[hook]) }.each { |hook| reinsert(entries[hook], name, handlers[hook]) }
        @work["events"].delete(name)
      end
      @data.delete(SPEC) if @data[SPEC].is_a?(Hash) && (@data[SPEC].keys - ["enabled"]).empty?
      @notes << "nothing to release" if events.empty?
      finish(event, "release", before, [], released_events: events)
    end

    def release_file(event)
      return @file if @file

      candidates = @loaded[:files].select do |entry|
        entry[:scope] == @scope && entry[:plugin].nil? && @loaded[:ledgers].key?(entry[:path]) && entry[:data].is_a?(Hash) &&
          entry[:data][SPEC].is_a?(Hash) && (event.nil? || entry[:data][SPEC][event].is_a?(Array))
      end
      if candidates.empty?
        fallback = @scope == "global" ? Harnesses::Antigravity.global_path : nil
        raise Refused, "no ordonnateur members#{event ? " on #{event}" : ''} in the #{@scope} hooks" unless fallback

        return fallback
      end
      if candidates.length > 1
        paths = candidates.map { |entry| entry[:path] }.join(", ")
        raise Refused, "several #{@scope} hook files hold ordonnateur members (#{paths}); release names one file"
      end
      candidates.first[:path]
    end

    def indent_of(text)
      match = text && text.match(/^([ \t]+)\S/)
      match ? match[1] : "  "
    end

    def render_json(data, text)
      json = JSON.pretty_generate(data, indent: indent_of(text))
      text.nil? || text.end_with?("\n") ? "#{json}\n" : json
    end

    def rewrite
      after = render_json(@data, @text)
      actual = begin
        JSON.parse(after)
      rescue JSON::ParserError
        nil
      end
      unless actual == @data
        @refusals << REWRITE_REFUSAL
        fail!
      end
      if @text && @text != render_json(@original, @text)
        @notes << "#{@path} is not in ordonnateur's JSON layout; this write also reformats it"
      end
      after
    end

    def tracked?(path)
      _out, status = Open3.capture2e("git", "-C", File.dirname(path), "ls-files", "--error-unmatch", path)
      status.success?
    rescue SystemCallError
      false
    end

    def finish(event, mode, before_ids, after_ids, leftovers: [], released_events: nil)
      changed = @data != @original
      after_text = changed ? rewrite : @text
      card_after = nil
      unless mode == "in_place"
        text = Harnesses::Antigravity.dump_ledger(@work)
        card_after = text == @ledger_text ? nil : text
      end
      if changed || card_after
        @notes << SESSION_NOTE
        @notes << "#{@path} is tracked by git; commit the change to share it" if @scope == "workspace" && tracked?(@path)
        unless leftovers.empty?
          @notes << "Hooks left in other hook specs on #{event} still run in an order that changes every session"
        end
      else
        @notes << "nothing to reorder"
      end
      plan = Plan.new(
        scope: @scope, settings_path: @path, card_path: @ledger_path, settings_text_before: @text,
        settings_text_after: after_text, card_text_before: @ledger_text, card_text_after: card_after,
        settings_sha: Digest::SHA256.hexdigest(@text.to_s), settings_mode: Harnesses::Antigravity.mode_of(@path),
        card_before: nil, card_after: nil, refusals: @refusals, notes: @notes, event: event,
        before_ids: before_ids, after_ids: after_ids, mode: mode, released_events: released_events
      )
      plan.verdicts = verdicts_for(plan)
      plan
    end

    def verdicts_for(plan)
      targets = []
      targets << [plan.settings_path, plan.settings_text_after] if plan.settings_text_after != plan.settings_text_before
      if plan.card_text_after && plan.card_text_after != plan.card_text_before
        targets << [plan.card_path, plan.card_text_after]
      end
      targets.map do |path, content|
        verdict = @ports.policy.judge(
          tool_name: "Write", tool_input: { "file_path" => path, "content" => content.to_s }, cwd: @cwd
        )
        [path, verdict]
      end
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
      lines << diff(plan.card_path, plan.card_text_before, plan.card_text_after) if plan.card_text_after
      lines.reject { |line| line.nil? || line.empty? }.join("\n")
    end

    def changed?(plan)
      plan.settings_text_after != plan.settings_text_before ||
        (!plan.card_text_after.nil? && plan.card_text_after != plan.card_text_before)
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
      current = Harnesses::Antigravity.read_text(plan.settings_path)
      unless Digest::SHA256.hexdigest(current.to_s) == plan.settings_sha
        raise SettingsChanged, "settings changed while planning; run again"
      end
      if plan.card_text_after && Harnesses::Antigravity.read_text(plan.card_path) != plan.card_text_before
        raise SettingsChanged, "settings changed while planning; run again"
      end

      if plan.settings_text_after != plan.settings_text_before
        Rplugin::AtomicFile.write(plan.settings_path, plan.settings_text_after, mode: plan.settings_mode || 0o600)
      end
      if plan.card_text_after && plan.card_text_after != plan.card_text_before
        Rplugin::AtomicFile.write(
          plan.card_path, plan.card_text_after, mode: Harnesses::Antigravity.mode_of(plan.card_path) || 0o600
        )
      end
      emit(plan)
      true
    end

    def backup(plan)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      dir = File.join(Rplugin::Paths.state_home, "ordonnateur", "backups")
      FileUtils.mkdir_p(dir)
      [plan.settings_path, plan.card_path].each do |path|
        next unless path && File.file?(path)

        base = File.join(dir, "#{stamp}-antigravity-#{plan.scope}-#{File.basename(path)}")
        target = base
        counter = 1
        while File.exist?(target)
          target = "#{base}.#{counter}"
          counter += 1
        end
        FileUtils.cp(path, target, preserve: true)
      end
    end

    def emit(plan)
      events = plan.released_events || [plan.event]
      events.each do |name|
        members = plan.released_events ? [] : plan.after_ids
        @ports.events.emit(
          "ordonnateur.card.applied",
          {
            "harness" => "antigravity", "scope" => plan.scope, "event" => name, "members" => members,
            "mode" => plan.mode, "via" => @via
          }
        )
      end
    end
  end
end
