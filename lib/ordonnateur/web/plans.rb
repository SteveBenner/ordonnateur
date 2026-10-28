#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "digest"
require "time"

require_relative "../antigravity_order"
require_relative "../canonical"
require_relative "../harnesses/antigravity"
require_relative "../harnesses/claude_code"
require_relative "../harnesses/hermes"
require_relative "../hermes_order"
require_relative "../inventory"
require_relative "../lint"
require_relative "../model"
require_relative "../overlay"
require_relative "../takeover"

module Ordonnateur
  module Web
    class Plans
      MAX_PLANS = 200
      TTL = 3600
      MAX_CHANGES = 200
      OPS = %w[order release guard unguard].freeze
      ANTIGRAVITY_SCOPES = %w[global workspace].freeze
      SCOPES = (%w[user local] + ANTIGRAVITY_SCOPES).freeze

      Record = Struct.new(:id, :request, :at, :body, :applied)

      def initialize(ports:, settings:, layout:)
        @ports = ports
        @settings = settings
        @layout = layout
        @records = {}
        @store_lock = Mutex.new
        @apply_lock = Mutex.new
      end

      def create(raw)
        project = project_param(raw["project"])
        scope = raw["scope"]
        raise Failure.new(422, "invalid", "scope must be user, local, global or workspace") unless SCOPES.include?(scope)
        raise Failure.new(422, "invalid", "local scope needs a project") if scope == "local" && project.nil?
        raise Failure.new(422, "invalid", "workspace scope needs a project") if scope == "workspace" && project.nil?
        raise Failure.new(422, "invalid", "base must be the config fingerprint") unless raw["base"].is_a?(String) && !raw["base"].empty?

        inventory = @layout.inventory_for(project)
        antigravity = ANTIGRAVITY_SCOPES.include?(scope)
        changes = validate_changes(raw["changes"], inventory, scope)
        hermes = !antigravity && hermes_draft?(changes, inventory)
        raise Failure.new(422, "invalid", "Hermes plans use scope user") if hermes && scope != "user"

        rows = @layout.timing_rows
        current = @layout.fingerprint_of(inventory, rows)
        base_moved!(current) unless current["config"] == raw["base"]
        request = { "scope" => scope, "project" => project, "changes" => changes }
        request["harness"] = "hermes" if hermes
        if antigravity
          request["harness"] = "antigravity"
          request["file"] = antigravity_file(changes, inventory, scope)
        end
        at = Time.at(Time.now.to_i).utc
        built = build_or_fail(request, at, project)
        body = describe(built, request, at, inventory, rows, project)
        store(Record.new(body["plan_id"], request, at, body, false))
        body
      end

      def fetch(id)
        record = find(id)
        raise Failure.new(404, "not_found", "no such plan") unless record

        record.body
      end

      def apply(id, confirm)
        @apply_lock.synchronize do
          record = find(id)
          raise Failure.new(404, "not_found", "no such plan") unless record
          raise Failure.new(409, "already_applied", "this plan was already applied", { reason: "already_applied" }) if record.applied
          raise Failure.new(403, "disabled", "ordonnateur web is disabled", { reason: "disabled" }) unless @settings.on?("web.enabled")

          rebuilt = rebuild(record)
          check_unchanged!(record, rebuilt)
          check_confirm!(record, confirm)
          check_applicable!(record)
          write(record, rebuilt)
        end
      end

      private

      def project_param(value)
        return nil if value.nil?

        unless value.is_a?(String) && value.start_with?("/") && !value.include?("\0") && File.directory?(value)
          raise Failure.new(422, "invalid", "project must be an absolute path to an existing directory")
        end
        value
      end

      def validate_changes(raw, inventory, scope)
        unless raw.is_a?(Array) && !raw.empty? && raw.length <= MAX_CHANGES
          raise Failure.new(422, "invalid", "changes must be a list of 1 to #{MAX_CHANGES} changes")
        end

        by_id = inventory.hooks.to_h { |hook| [hook.id, hook] }
        if ANTIGRAVITY_SCOPES.include?(scope)
          changes = raw.map { |item| normalize_antigravity(item, by_id, scope) }
          check_events!(changes, by_id)
          check_one_file!(changes, by_id)
          return changes
        end

        changes = raw.map { |item| normalize_change(item, by_id) }
        kinds = changes.map { |change| hermes_change?(change, by_id) }.uniq
        raise Failure.new(422, "invalid", "a draft cannot mix Hermes and Claude Code changes") if kinds.length > 1

        check_events!(changes, by_id)
        changes
      end

      def normalize_antigravity(item, by_id, scope)
        raise Failure.new(422, "invalid", "each change must be an object") unless item.is_a?(Hash)

        op = item["op"]
        raise Failure.new(422, "invalid", "unknown op #{op.inspect}") unless OPS.include?(op)

        case op
        when "order"
          event = event_name(item["event"], "antigravity")
          hooks = item["hooks"]
          unless hooks.is_a?(Array) && !hooks.empty? && hooks.all? { |id| id.is_a?(String) && !id.empty? }
            raise Failure.new(422, "invalid", "order needs a non-empty list of hook ids")
          end
          raise Failure.new(422, "invalid", "stop_on_block applies to Claude Code only") unless item["stop_on_block"].nil?

          known = hooks.map { |id| known_hook(id, by_id) }
          check_antigravity_order!(event, known, scope)
          { "op" => "order", "event" => event, "hooks" => hooks }
        when "release"
          { "op" => "release", "event" => event_name(item["event"], "antigravity") }
        else
          hook = known_hook(item["hook"], by_id)
          if hook.harness == "antigravity"
            raise Failure.new(422, "refused", "#{hook.id} is an Antigravity hook and Antigravity has no cards", { refusals: ["#{hook.id}: Antigravity has no cards"] })
          end

          raise Failure.new(422, "invalid", "a draft cannot mix Antigravity with other harnesses")
        end
      end

      def check_antigravity_order!(event, known, scope)
        unless known.all? { |hook| hook.harness == "antigravity" }
          raise Failure.new(422, "invalid", "a draft cannot mix Antigravity with other harnesses")
        end

        plugin = known.find(&:plugin)
        if plugin
          raise Failure.new(422, "refused", "#{plugin.id} is a plugin hook and plugin files are read-only", { refusals: ["#{plugin.id}: plugin hooks are read-only"] })
        end
        raise Failure.new(422, "invalid", "all hooks of an order must be on #{event}") unless known.all? { |hook| hook.event == event }

        stray = known.find { |hook| hook.scope != scope }
        raise Failure.new(422, "invalid", "#{stray.id} is in the #{stray.scope} hooks, not the #{scope} hooks of this plan") if stray
        raise Failure.new(422, "invalid", "all hooks of an order must be in one file") unless known.map(&:source_file).uniq.length == 1
      end

      def check_one_file!(changes, by_id)
        files = changes.select { |change| change["op"] == "order" }.flat_map { |change| change["hooks"].map { |id| by_id[id].source_file } }.uniq
        raise Failure.new(422, "invalid", "all changes of a draft must be in one file") if files.length > 1
      end

      def antigravity_file(changes, inventory, scope)
        return nil unless scope == "workspace"

        by_id = inventory.hooks.to_h { |hook| [hook.id, hook] }
        order = changes.find { |change| change["op"] == "order" }
        order ? by_id[order["hooks"].first].source_file : nil
      end

      def hermes_change?(change, by_id)
        change["op"] == "order" && by_id[change["hooks"].first]&.harness == "hermes"
      end

      def hermes_draft?(changes, inventory)
        by_id = inventory.hooks.to_h { |hook| [hook.id, hook] }
        changes.any? { |change| hermes_change?(change, by_id) }
      end

      def hermes_refusal!(id)
        raise Failure.new(422, "refused", "#{id} is a Hermes hook and Hermes has no cards", { refusals: ["#{id}: Hermes has no cards"] })
      end

      def normalize_change(item, by_id)
        raise Failure.new(422, "invalid", "each change must be an object") unless item.is_a?(Hash)

        op = item["op"]
        raise Failure.new(422, "invalid", "unknown op #{op.inspect}") unless OPS.include?(op)

        case op
        when "order"
          first = item["hooks"].first if item["hooks"].is_a?(Array)
          event = event_name(item["event"], by_id[first]&.harness == "hermes" ? "hermes" : "claude-code")
          hooks = item["hooks"]
          unless hooks.is_a?(Array) && !hooks.empty? && hooks.all? { |id| id.is_a?(String) && !id.empty? }
            raise Failure.new(422, "invalid", "order needs a non-empty list of hook ids")
          end
          flag = item["stop_on_block"]
          raise Failure.new(422, "invalid", "stop_on_block must be true or false") unless flag.nil? || [true, false].include?(flag)

          known = hooks.map { |id| known_hook(id, by_id) }
          antigravity_scope!(known)
          change = { "op" => "order", "event" => event, "hooks" => hooks }
          change["stop_on_block"] = flag unless flag.nil?
          check_hermes_order!(change, known, flag)
          change
        when "release"
          hermes_release!(item, by_id)
          { "op" => "release", "event" => event_name(item["event"]) }
        else
          hook = known_hook(item["hook"], by_id)
          hermes_refusal!(hook.id) if hook.harness == "hermes"
          if hook.harness == "antigravity"
            raise Failure.new(422, "refused", "#{hook.id} is an Antigravity hook and Antigravity has no cards", { refusals: ["#{hook.id}: Antigravity has no cards"] })
          end

          { "op" => op, "hook" => hook.id }
        end
      end

      def antigravity_scope!(known)
        return unless known.any? { |hook| hook.harness == "antigravity" }

        raise Failure.new(422, "invalid", "Antigravity plans use scope global or workspace and hold no other harness")
      end

      def check_hermes_order!(change, known, flag)
        harnesses = known.map(&:harness).uniq
        return unless harnesses.include?("hermes")

        raise Failure.new(422, "invalid", "an order cannot mix Hermes and Claude Code hooks") if harnesses.length > 1
        raise Failure.new(422, "invalid", "stop_on_block applies to Claude Code only") unless flag.nil?

        event = change["event"]
        raise Failure.new(422, "invalid", "all hooks of an order must be on #{event}") unless known.all? { |hook| hook.event == event }
      end

      def hermes_release!(item, by_id)
        hook = by_id[item["hook"]] if item["hook"].is_a?(String)
        hermes_refusal!(hook.id) if hook&.harness == "hermes"
        event = item["event"]
        return unless event.is_a?(String) && Model::HERMES_EVENTS.include?(event) && !Model::CLAUDE_EVENTS.include?(event)

        raise Failure.new(422, "refused", "#{event} is a Hermes event and Hermes has no cards", { refusals: ["#{event}: Hermes has no cards"] })
      end

      def event_name(value, harness = "claude-code")
        return value if value.is_a?(String) && Model.events_for(harness).include?(value)

        label = { "hermes" => "Hermes", "antigravity" => "Antigravity" }.fetch(harness, "Claude Code")
        raise Failure.new(422, "invalid", "unknown #{label} event #{value.inspect}")
      end

      def known_hook(id, by_id)
        hook = by_id[id] if id.is_a?(String)
        raise Failure.new(422, "invalid", "unknown hook #{id.inspect}") unless hook
        raise Failure.new(422, "refused", "#{id} is a Codex hook and Codex is read-only", { refusals: ["#{id}: Codex is read-only"] }) if hook.harness == "codex"

        hook
      end

      def check_events!(changes, by_id)
        moved = changes.select { |change| %w[order release].include?(change["op"]) }.map { |change| change["event"] }
        duplicate = moved.find { |event| moved.count(event) > 1 }
        raise Failure.new(422, "invalid", "#{duplicate} has more than one order or release") if duplicate

        guarded = changes.select { |change| %w[guard unguard].include?(change["op"]) }.map { |change| change["hook"] }
        repeated = guarded.find { |id| guarded.count(id) > 1 }
        raise Failure.new(422, "conflict_in_draft", "#{repeated} has more than one guard or unguard") if repeated

        guarded.each do |id|
          next unless moved.include?(by_id[id].event)

          raise Failure.new(422, "conflict_in_draft", "#{id} is on #{by_id[id].event}, which the same draft orders or releases")
        end
      end

      def base_moved!(current)
        raise Failure.new(409, "base_moved", "the hook settings changed after the draft was based", { fingerprint: current })
      end

      def takeover_for(request, at)
        project = request["project"]
        root = Harnesses::ClaudeCode.project_root(project || Web.empty_root)
        cwd = request["scope"] == "local" ? root : Dir.home
        Takeover.new(scope: request["scope"], project: root, ports: @ports, cwd: cwd, via: "web", at: at)
      end

      def build(request, at)
        return build_hermes(request, at) if request["harness"] == "hermes"
        return build_antigravity(request, at) if request["harness"] == "antigravity"

        takeover = takeover_for(request, at)
        changes = request["changes"]
        plan = nil
        changes.select { |change| change["op"] == "guard" }.each { |change| plan = takeover.plan_guard(change["hook"]) }
        changes.select { |change| change["op"] == "unguard" }.each { |change| plan = takeover.plan_unguard(change["hook"]) }
        changes.select { |change| %w[order release].include?(change["op"]) }.each do |change|
          plan =
            if change["op"] == "order"
              takeover.plan_order(change["event"], change["hooks"], stop_on_block: change["stop_on_block"])
            else
              takeover.plan_release(change["event"])
            end
        end
        { takeover: takeover, plan: plan, plan_id: plan_id(plan) }
      end

      def build_hermes(request, at)
        path = Harnesses::Hermes.config_path
        original = Harnesses::Hermes.read_text(path)
        text = original
        orders = []
        steps = []
        engine = nil
        request["changes"].each do |change|
          engine, step = Overlay.with({ path => text }) do
            order = HermesOrder.new(ports: @ports, cwd: Dir.home, via: "web", at: at)
            [order, order.plan_order(change["event"], change["hooks"])]
          end
          steps << step
          text = step.settings_text_after
          next if step.before_ids == step.after_ids

          orders << { "event" => change["event"], "before" => step.before_ids, "after" => step.after_ids }
        end
        plan = combine_hermes(steps, original, path, engine)
        { takeover: engine, plan: plan, plan_id: plan_id(plan), orders: orders }
      end

      def combine_hermes(steps, original, path, engine)
        plan = steps.last.dup
        plan.settings_text_before = original
        plan.settings_sha = Digest::SHA256.hexdigest(original.to_s)
        plan.settings_mode = Harnesses::Hermes.mode_of(path)
        changed = plan.settings_text_after != original
        plan.notes = steps.flat_map(&:notes).uniq.reject { |note| changed && note == "nothing to reorder" }
        plan.refusals = steps.flat_map(&:refusals).uniq
        moved = steps.reverse.find { |step| step.before_ids != step.after_ids }
        plan.event = moved.event if moved
        plan.before_ids = moved.before_ids if moved
        plan.after_ids = moved.after_ids if moved
        plan.verdicts = engine.verdicts_for(plan)
        plan
      end

      def build_antigravity(request, at)
        project = request["project"]
        scope = request["scope"]
        cwd = scope == "workspace" ? Harnesses::ClaudeCode.project_root(project) : Dir.home
        overlay = {}
        steps = []
        orders = []
        reorder = true
        engine = nil
        request["changes"].each do |change|
          engine, step, members = Overlay.with(overlay) do
            order = AntigravityOrder.new(
              scope: scope, project: project || Web.empty_root, ports: @ports, cwd: cwd, via: "web", at: at,
              file: request["file"]
            )
            planned =
              if change["op"] == "order"
                order.plan_order(change["event"], change["hooks"])
              else
                order.plan_release(change["event"])
              end
            [order, planned, order.members_of(change["event"]).map(&:id)]
          end
          steps << step
          reorder &&= step.mode == "in_place" || (step.mode == "members" && members.sort == step.after_ids.sort)
          overlay = {}
          overlay[step.settings_path] = step.settings_text_after unless step.settings_text_after.nil?
          ledger = step.card_text_after || step.card_text_before
          overlay[step.card_path] = ledger unless ledger.nil?
          next if step.before_ids == step.after_ids && step.mode == "in_place"

          orders << { "event" => change["event"], "before" => step.before_ids, "after" => step.after_ids }
        end
        plan = combine_antigravity(steps, engine)
        { takeover: engine, plan: plan, plan_id: plan_id(plan), orders: orders, reorder: reorder }
      end

      def combine_antigravity(steps, engine)
        first = steps.first
        plan = steps.last.dup
        plan.settings_text_before = first.settings_text_before
        plan.settings_sha = first.settings_sha
        plan.settings_mode = first.settings_mode
        plan.card_text_before = first.card_text_before
        final = steps.reverse.map(&:card_text_after).compact.first
        plan.card_text_after = final == first.card_text_before ? nil : final
        changed = plan.settings_text_after != plan.settings_text_before || !plan.card_text_after.nil?
        plan.notes = steps.flat_map(&:notes).uniq.reject { |note| changed && note == "nothing to reorder" }
        plan.refusals = steps.flat_map(&:refusals).uniq
        moved = steps.reverse.find { |step| step.before_ids != step.after_ids }
        if moved
          plan.event = moved.event
          plan.before_ids = moved.before_ids
          plan.after_ids = moved.after_ids
          plan.mode = moved.mode
          plan.released_events = moved.released_events
        end
        plan.verdicts = engine.verdicts_for(plan)
        plan
      end

      def build_or_fail(request, at, project)
        build(request, at)
      rescue Refused => e
        raise Failure.new(422, "refused", "the change is refused", { refusals: refusal_lines(e.message) })
      rescue SettingsChanged
        base_moved!(@layout.fingerprint(project))
      rescue Usage => e
        raise Failure.new(422, "invalid", e.message)
      rescue HarnessFileError => e
        raise Failure.new(422, "harness_file_error", e.message)
      end

      def rebuild(record)
        build(record.request, record.at)
      rescue Refused, Usage, SettingsChanged, HarnessFileError
        raise Failure.new(409, "plan_changed", "the hook settings changed after this plan was made", { reason: "plan_changed" })
      end

      def refusal_lines(message)
        lines = message.lines.map(&:strip).reject(&:empty?)
        lines.shift if lines.first == "refused:"
        lines.empty? ? [message] : lines
      end

      def verdict_rows(plan)
        plan.verdicts.map do |path, verdict|
          { "path" => path, "verdict" => verdict[:verdict], "rule_id" => verdict[:rule_id], "reason" => verdict[:reason].to_s }
        end
      end

      def plan_id(plan)
        data = {
          "scope" => plan.scope, "settings_path" => plan.settings_path, "settings_sha" => plan.settings_sha,
          "settings_text_after" => plan.settings_text_after, "card_path" => plan.card_path,
          "card_sha_before" => Digest::SHA256.hexdigest(plan.card_text_before.to_s),
          "card_text_after" => plan.card_text_after, "verdicts" => verdict_rows(plan)
        }
        "pl_#{Digest::SHA256.hexdigest(Canonical.json(data))[0, 16]}"
      end

      def classification(plan, built = nil)
        return "reorder" if plan.is_a?(HermesOrder::Plan)
        return built && built[:reorder] ? "reorder" : "change" if plan.is_a?(AntigravityOrder::Plan)

        before = plan.card_before
        return "change" if before.nil? || plan.settings_text_after != plan.settings_text_before
        return "change" unless before["unguarded"] == plan.card_after["unguarded"]

        old = before["events"]
        new = plan.card_after["events"]
        (old.keys | new.keys).each do |event|
          left = old[event]
          right = new[event]
          return "change" if left.nil? || right.nil?
          return "change" unless left["members"].map { |member| member["id"] }.sort == right["members"].map { |member| member["id"] }.sort
          return "change" unless left["stop_on_block"] == right["stop_on_block"]
        end
        "reorder"
      end

      def blocked_reason(takeover, plan, verdicts)
        return "nothing_to_apply" unless takeover.changed?(plan)

        names = verdicts.map { |row| row["verdict"] }
        return "policy_deny" if names.include?("deny")
        return "policy_warn" if names.include?("warn")

        nil
      end

      def lint_after(plan, rows, project)
        overlay = { plan.settings_path => plan.settings_text_after }
        overlay[plan.card_path] = plan.card_text_after if plan.card_path && (plan.card_text_after || !plan.is_a?(AntigravityOrder::Plan))
        Overlay.with(overlay) { @layout.findings(@layout.inventory_for(project), rows) }
      end

      def file_rows(takeover, plan)
        card_path = plan.card_path
        card_path = nil if plan.is_a?(AntigravityOrder::Plan) && plan.card_text_after.nil?
        [
          [plan.settings_path, plan.settings_text_before, plan.settings_text_after],
          [card_path, plan.card_text_before, plan.card_text_after]
        ].reject { |path, _, _| path.nil? }.map do |path, before, after|
          {
            "path" => path, "sha_before" => Digest::SHA256.hexdigest(before.to_s),
            "diff" => takeover.diff(path, before, after).to_s, "changes" => before.to_s != after.to_s
          }
        end
      end

      def describe(built, request, at, inventory, rows, project)
        takeover = built[:takeover]
        plan = built[:plan]
        verdicts = verdict_rows(plan)
        kind = classification(plan, built)
        reason = blocked_reason(takeover, plan, verdicts)
        before = @layout.findings(inventory, rows)
        after = lint_after(plan, rows, project)
        before_ids = before.map { |item| item["id"] }
        after_ids = after.map { |item| item["id"] }
        {
          "plan_id" => built[:plan_id], "scope" => request["scope"], "project" => project, "classification" => kind,
          "needs_confirm" => kind == "change", "applicable" => reason.nil?, "blocked_reason" => reason,
          "files" => file_rows(takeover, plan), "verdicts" => verdicts, "card_before" => plan.card_before,
          "card_after" => plan.card_after,
          "lint" => { "before" => before, "after" => after, "added" => after_ids - before_ids, "resolved" => before_ids - after_ids },
          "effects_text" => effects_text(plan),
          "notes" => plan.notes, "created_at" => at.iso8601, "orders" => built[:orders] || []
        }
      end

      def effects_text(plan)
        return HermesOrder::RESTART_NOTE if plan.is_a?(HermesOrder::Plan)
        return AntigravityOrder::SESSION_NOTE if plan.is_a?(AntigravityOrder::Plan)

        EFFECTS_TEXT
      end

      def check_unchanged!(record, rebuilt)
        return if rebuilt[:plan_id] == record.id

        raise Failure.new(409, "plan_changed", "the hook settings changed after this plan was made", { reason: "plan_changed", plan_id: rebuilt[:plan_id] })
      end

      def check_confirm!(record, confirm)
        return unless record.body["needs_confirm"] && confirm != record.id

        raise Failure.new(422, "confirm_required", "type the plan id to apply this plan", { plan_id: record.id })
      end

      def check_applicable!(record)
        return if record.body["applicable"]

        reason = record.body["blocked_reason"]
        raise Failure.new(422, reason, blocked_message(record, reason), { plan_id: record.id })
      end

      def blocked_message(record, reason)
        case reason
        when "nothing_to_apply" then "nothing would change"
        else
          rows = record.body["verdicts"].select { |row| row["verdict"] == (reason == "policy_deny" ? "deny" : "warn") }
          rows.map { |row| "#{row['path']}: #{row['reason']}" }.join("; ")
        end
      end

      def write(record, rebuilt)
        takeover = rebuilt[:takeover]
        plan = rebuilt[:plan]
        backups_dir = File.join(Rplugin::Paths.state_home, "ordonnateur", "backups")
        known = Dir.glob(File.join(backups_dir, "*"))
        begin
          takeover.apply(plan)
        rescue Refused => e
          raise Failure.new(422, "refused", e.message, { refusals: [e.message] })
        rescue SettingsChanged
          raise Failure.new(409, "plan_changed", "the hook settings changed after this plan was made", { reason: "plan_changed" })
        end
        record.applied = true
        written = []
        written << plan.settings_path if plan.settings_text_after != plan.settings_text_before
        card_written = plan.card_text_after != plan.card_text_before
        card_written &&= !plan.card_text_after.nil? if plan.is_a?(AntigravityOrder::Plan)
        written << plan.card_path if card_written
        {
          "plan_id" => record.id, "applied" => true, "files" => written,
          "backups" => (Dir.glob(File.join(backups_dir, "*")) - known).sort,
          "fingerprint" => @layout.fingerprint(record.request["project"])
        }
      end

      def store(record)
        @store_lock.synchronize do
          purge
          @records.delete(record.id)
          @records.shift while @records.length >= MAX_PLANS
          @records[record.id] = record
        end
      end

      def find(id)
        @store_lock.synchronize do
          purge
          @records[id]
        end
      end

      def purge
        limit = Time.now.utc - TTL
        @records.delete_if { |_, record| record.at < limit }
      end
    end
  end
end
