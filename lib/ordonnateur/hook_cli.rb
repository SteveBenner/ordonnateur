#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "digest"
require "json"

require_relative "model"
require_relative "inventory"
require_relative "takeover"
require_relative "hermes_order"
require_relative "antigravity_order"
require_relative "canonical"
require_relative "hook_script"
require_relative "script_edit"
require_relative "provenance/facade"

module Ordonnateur
  module HookCli
    EDIT_OFF = "editing and deleting hooks is turned off; the user turns it on in a terminal with: rplugin settings set ordonnateur web.hook_edit true".freeze

    def hook_edit_on!
      raise Refused, EDIT_OFF unless settings.on?("web.hook_edit")
    end

    def hook_target(ref, project)
      inventory = full_inventory(harness: "all", project: project)
      [Inventory.resolve(inventory.hooks, ref), inventory]
    end

    def script_root(project, inventory)
      project ? inventory.root : nil
    end

    def delete_engine(hook, project)
      case hook.harness
      when "hermes" then HermesOrder.new(ports: ports, via: "cli")
      when "antigravity"
        AntigravityOrder.new(
          scope: hook.scope, project: hook.scope == "workspace" ? project || Dir.pwd : nil, ports: ports, via: "cli",
          file: hook.scope == "workspace" ? hook.source_file : nil
        )
      else
        Takeover.new(scope: hook.scope, project: project, ports: ports, via: "cli")
      end
    end

    def delete_plan_id(plan)
      rows = plan.verdicts.map do |path, verdict|
        { "path" => path, "verdict" => verdict[:verdict], "rule_id" => verdict[:rule_id], "reason" => verdict[:reason].to_s }
      end
      data = {
        "scope" => plan.scope, "settings_path" => plan.settings_path, "settings_sha" => plan.settings_sha,
        "settings_text_after" => plan.settings_text_after, "card_path" => plan.card_path,
        "card_sha_before" => Digest::SHA256.hexdigest(plan.card_text_before.to_s),
        "card_text_after" => plan.card_text_after, "verdicts" => rows
      }
      Canonical.plan_id(data)
    end

    def hook_flags(parser, opts)
      parser.on("--project DIR") { |v| opts[:project] = v }
      parser.on("--json") { opts[:json] = true }
      parser.on("--content") { opts[:content] = true }
      parser.on("--from-file PATH") { |v| opts[:from_file] = v }
      parser.on("--stdin") { opts[:stdin] = true }
      parser.on("--apply") { opts[:apply] = true }
      parser.on("--confirm ID") { |v| opts[:confirm] = v }
    end

    def cmd_hook(argv, out, _err)
      sub = argv.shift
      raise Usage, "usage: #{Cli::USAGE['hook']}" unless %w[show edit delete].include?(sub)

      options = parse(argv, Cli::USAGE["hook"]) { |parser, opts| hook_flags(parser, opts) }
      raise Usage, "usage: #{Cli::USAGE['hook']}" unless argv.length == 1

      send("hook_#{sub}", argv.first, options, out)
    end

    def hook_show(ref, options, out)
      hook, inventory = hook_target(ref, options[:project])
      root = script_root(options[:project], inventory)
      script = HookScript.resolve(hook, project_root: root)
      edit = HookScript.editability(hook, hooks: inventory.hooks, project_root: root)
      delete = HookScript.deletability(hook, hooks: inventory.hooks, project_root: root)
      edit_on = settings.on?("web.hook_edit")
      if options[:json]
        data = script.to_h.transform_keys(&:to_s)
        data["content"] = nil unless options[:content]
        out.puts JSON.pretty_generate(
          { "hook" => hook.to_h, "script" => data, "editable" => edit, "deletable" => delete, "hook_edit" => edit_on }
            .transform_values { |value| value.is_a?(Hash) ? value.transform_keys(&:to_s) : value }
        )
        return 0
      end
      out.puts "hook #{hook.id}"
      out.puts "  #{hook.harness} #{hook.scope} #{hook.event}"
      out.puts "  command #{hook.command}"
      out.puts "  script #{script.path || 'none'} (#{script.kind}#{script.resolved_from ? ", from #{script.resolved_from}" : ''})"
      out.puts "  size #{script.size} bytes, #{script.line_count} lines, modified #{script.mtime}, sha256 #{script.sha256}" if script.sha256
      out.puts "  script note: #{script.refusal}" if script.refusal
      out.puts "  edit script: #{edit[:allowed] ? 'allowed' : "refused, #{edit[:refusal]}"}"
      out.puts "  delete hook: #{delete[:allowed] ? 'allowed' : "refused, #{delete[:refusal]}"}"
      out.puts "  web.hook_edit is #{edit_on ? 'on' : 'off'}; edit and delete need it on"
      out.puts script.content if options[:content] && script.content
      0
    end

    def hook_edit(ref, options, out)
      raise Usage, "usage: #{Cli::USAGE['hook']}" unless options[:from_file].nil? ^ options[:stdin].nil?
      raise Usage, "--confirm needs --apply" if options[:confirm] && !options[:apply]
      raise Usage, "--apply needs --confirm PLAN_ID, the id printed by the plan" if options[:apply] && options[:confirm].nil?

      hook_edit_on!
      content = hook_edit_input(options)
      hook, inventory = hook_target(ref, options[:project])
      root = script_root(options[:project], inventory)
      script = HookScript.resolve(hook, project_root: root)
      engine = ScriptEdit.new(ports: ports, via: "cli", cwd: Dir.pwd)
      plan = engine.plan(hook: hook, hooks: inventory.hooks, content: content, base_sha: script.sha256.to_s, project_root: root)
      finish_hook_plan(engine, plan, plan.plan_id, options, out) { engine.apply(plan) }
    end

    def hook_edit_input(options)
      limit = ScriptEdit::MAX_BYTES
      text =
        if options[:stdin]
          $stdin.read(limit + 1)
        else
          File.open(options[:from_file], "rb") { |file| file.read(limit + 1) }
        end.to_s
      raise Refused, "the script text is above #{limit} bytes" if text.bytesize > limit

      text.force_encoding(Encoding::UTF_8)
    rescue SystemCallError => e
      raise Refused, "the script text cannot be read: #{e.message}"
    end

    def hook_delete(ref, options, out)
      raise Usage, "--confirm needs --apply" if options[:confirm] && !options[:apply]
      raise Usage, "--apply needs --confirm PLAN_ID, the id printed by the plan" if options[:apply] && options[:confirm].nil?

      hook_edit_on!
      hook, = hook_target(ref, options[:project])
      engine = delete_engine(hook, options[:project])
      plan = engine.plan_delete(hook.id)
      id = delete_plan_id(plan)
      finish_hook_plan(engine, plan, id, options, out) { engine.apply(plan, plan_id: id) }
    end

    def finish_hook_plan(engine, plan, id, options, out)
      if options[:json]
        out.puts JSON.pretty_generate(hook_plan_json(engine, plan, id))
      else
        out.puts engine.render(plan)
        out.puts "plan #{id}"
      end
      changed = engine.changed?(plan)
      unless options[:apply]
        out.puts "not applied; to write this, run again with --apply --confirm #{id}" if changed && !options[:json]
        out.puts "no changes" if !changed && !options[:json]
        return 0
      end
      raise Usage, "--confirm #{options[:confirm]} does not match the plan id #{id}" unless options[:confirm] == id
      raise Refused, "nothing would change" unless changed

      result = yield
      out.puts(options[:json] ? JSON.generate({ "applied" => true, "plan_id" => id }) : "applied #{id}") if result
      0
    end

    def hook_plan_json(engine, plan, id)
      verdicts = plan.verdicts.map do |row|
        row.is_a?(Hash) ? row : { "path" => row[0], "verdict" => row[1][:verdict], "rule_id" => row[1][:rule_id], "reason" => row[1][:reason].to_s }
      end
      { "plan_id" => id, "classification" => plan.classification, "hold_required" => plan.hold_required,
        "changes" => engine.changed?(plan), "verdicts" => verdicts, "rendered" => engine.render(plan) }
    end

    def cmd_provenance(argv, out, _err)
      options = parse(argv, Cli::USAGE["provenance"]) do |parser, opts|
        parser.on("--limit N", Integer) { |v| opts[:limit] = v }
        parser.on("--json") { opts[:json] = true }
      end
      raise Usage, "usage: #{Cli::USAGE['provenance']}" if argv.length > 1

      limit = options[:limit] || 200
      raise Usage, "--limit must be from 1 to 1000" unless limit.between?(1, 1000)

      id = argv.first
      id = hook_id_for(id) if id
      store = Provenance::Facade.for(ports: ports, settings: settings)
      events = store.history(hook_id: id, limit: limit)
      status = store.status
      if options[:json]
        out.puts JSON.pretty_generate(
          { "store" => status[:store], "degraded" => status[:degraded], "note" => status[:note], "events" => events }
        )
        return 0
      end
      out.puts "note: #{status[:note]}" if status[:note]
      events.each do |event|
        out.puts "#{event['at']}  #{event['kind'].ljust(11)} #{event['hook_id']}  via #{event['via'] || '-'}  basis #{event['basis']}"
      end
      out.puts "#{events.length} event(s)"
      0
    end

    def hook_id_for(ref)
      Inventory.resolve(full_inventory(harness: "all", project: nil).hooks, ref).id
    rescue Usage
      ref
    end
  end
end
