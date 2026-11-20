#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "digest"
require "fileutils"
require "open3"
require "time"
require "timeout"
require "tmpdir"

require_relative "model"
require_relative "canonical"
require_relative "hook_script"

module Ordonnateur
  class ScriptEdit
    class BaseMoved < Refused
    end

    Plan = Struct.new(
      :plan_id, :scope, :project, :classification, :needs_confirm, :hold_required, :applicable, :blocked_reason,
      :files, :verdicts, :lint, :effects_text, :notes, :created_at, :orders, :path, :sha_before, :content_before,
      :content_after, :mode, :hook_id, :harness, :event, :source_file, keyword_init: true
    ) do
      def to_h
        {
          "plan_id" => plan_id, "scope" => scope, "project" => project, "classification" => classification,
          "needs_confirm" => needs_confirm, "hold_required" => hold_required, "applicable" => applicable,
          "blocked_reason" => blocked_reason, "files" => files, "verdicts" => verdicts, "lint" => lint,
          "effects_text" => effects_text, "notes" => notes, "created_at" => created_at, "orders" => orders
        }
      end
    end

    Subject = Struct.new(:id, :harness, :scope, :plugin, :event, :source_file, keyword_init: true)

    MAX_BYTES = 256 * 1024
    DIFF_TIMEOUT = 5
    EFFECTS_TEXT = "The script file is rewritten in place and a backup is kept; every hook that runs it uses the new text from its next run."

    def initialize(ports:, via: "cli", at: nil, cwd: Dir.pwd)
      @ports = ports
      @via = via
      @at = at
      @cwd = cwd
    end

    def plan(hook:, hooks:, content:, base_sha:, project_root: nil)
      editable = HookScript.editability(hook, hooks: hooks, project_root: project_root)
      raise Refused, "refused:\n  #{hook.id}: #{editable[:refusal]}" unless editable[:allowed]

      script = HookScript.resolve(hook, project_root: project_root)
      validate_content!(content)
      raise BaseMoved, "#{script.path} changed since the text was read" unless script.sha256 == base_sha

      text = content.dup.force_encoding(Encoding::UTF_8)
      verdicts = judge(script.path, text)
      build(hook, script, text, verdicts, project_root)
    end

    def validate_content!(content)
      raise Usage, "content must be a string" unless content.is_a?(String)
      raise Refused, "the script text is above #{MAX_BYTES} bytes" if content.bytesize > MAX_BYTES

      text = content.dup.force_encoding(Encoding::UTF_8)
      raise Refused, "the script text is not valid UTF-8" unless text.valid_encoding?
      raise Refused, "the script text contains a NUL byte" if text.include?("\0")
    end

    def judge(path, text)
      verdict = @ports.policy.judge(
        tool_name: "Write", tool_input: { "file_path" => path, "content" => text }, cwd: @cwd
      )
      [[path, verdict]]
    end

    def verdict_rows(verdicts)
      verdicts.map do |path, verdict|
        { "path" => path, "verdict" => verdict[:verdict], "rule_id" => verdict[:rule_id], "reason" => verdict[:reason] }
      end
    end

    def self.compute_id(path, sha_before, content_after, rows)
      Canonical.plan_id({ "path" => path, "sha_before" => sha_before, "content_after" => content_after, "verdicts" => rows })
    end

    def build(hook, script, text, verdicts, project_root)
      rows = verdict_rows(verdicts)
      changed = text != script.content
      names = rows.map { |row| row["verdict"] }
      reason =
        if !changed then "nothing_to_apply"
        elsif names.include?("deny") then "policy_deny"
        elsif names.include?("warn") then "policy_warn"
        end
      Plan.new(
        plan_id: self.class.compute_id(script.path, script.sha256, text, rows), scope: hook.scope,
        project: project_root, classification: "script_edit", needs_confirm: false, hold_required: true,
        applicable: reason.nil?, blocked_reason: reason,
        files: [{
          "path" => script.path, "sha_before" => script.sha256, "diff" => diff(script.path, script.content, text).to_s,
          "changes" => changed
        }],
        verdicts: rows, lint: { "before" => [], "after" => [], "added" => [], "resolved" => [] },
        effects_text: EFFECTS_TEXT, notes: [], created_at: (@at || Time.now).utc.iso8601, orders: [],
        path: script.path, sha_before: script.sha256, content_before: script.content, content_after: text,
        mode: File.stat(script.path).mode & 0o7777, hook_id: hook.id, harness: hook.harness, event: hook.event,
        source_file: hook.source_file
      )
    end

    def changed?(plan)
      plan.content_after != plan.content_before
    end

    def diff(path, before, after)
      return nil if before.to_s == after.to_s

      Dir.mktmpdir("ordonnateur-diff") do |dir|
        left = File.join(dir, "before")
        right = File.join(dir, "after")
        File.write(left, before.to_s)
        File.write(right, after.to_s)
        run_diff(path, left, right).chomp
      end
    end

    def run_diff(path, left, right)
      Open3.popen2("diff", "-u", "--label", path, "--label", path, left, right, err: File::NULL) do |stdin, stdout, waiter|
        stdin.close
        begin
          Timeout.timeout(DIFF_TIMEOUT) { stdout.read }
        rescue Timeout::Error
          begin
            Process.kill("KILL", waiter.pid)
          rescue SystemCallError
            nil
          end
          waiter.join
          raise Refused, "the diff timed out after #{DIFF_TIMEOUT} seconds"
        end
      end
    end

    def render(plan)
      lines = []
      plan.verdicts.each do |row|
        lines << "policy: write #{row['path']}: #{row['verdict']}#{row['rule_id'] ? " (#{row['rule_id']})" : ''} #{row['reason']}".rstrip
      end
      lines << plan.files.first["diff"]
      lines.reject { |line| line.nil? || line.empty? }.join("\n")
    end

    def check_verdicts!(plan)
      plan.verdicts.each do |row|
        case row["verdict"]
        when "deny"
          raise Refused, "polispec denies writing #{row['path']}: #{row['reason']} (#{row['rule_id']})"
        when "warn"
          raise Refused, "polispec warns on writing #{row['path']}: #{row['reason']}; ask the user, then the user runs this command; ordonnateur never proceeds on a warn"
        end
      end
    end

    def apply(plan)
      raise Refused, "nothing would change" unless changed?(plan)

      expected = self.class.compute_id(plan.path, plan.sha_before, plan.content_after, plan.verdicts)
      raise SettingsChanged, "the plan does not match its id; run again" unless expected == plan.plan_id

      check_verdicts!(plan)
      current = current_bytes(plan.path)
      unless Digest::SHA256.hexdigest(current) == plan.sha_before
        raise SettingsChanged, "#{plan.path} changed while planning; run again"
      end

      backup = backup(plan)
      Rplugin::AtomicFile.write(plan.path, plan.content_after, mode: plan.mode)
      sha_after = Digest::SHA256.hexdigest(plan.content_after.b)
      announce(plan, sha_after)
      { path: plan.path, backup: backup, sha_before: plan.sha_before, sha_after: sha_after }
    end

    def current_bytes(path)
      raise SettingsChanged, "#{path} is no longer the planned file; run again" unless File.file?(path) && File.realpath(path) == path

      raise SettingsChanged, "#{path} is above #{HookScript::SERVE_LIMIT} bytes now; run again" if File.size(path) > HookScript::SERVE_LIMIT

      bytes = File.open(path, "rb") { |file| file.read(HookScript::SERVE_LIMIT + 1) }.to_s
      raise SettingsChanged, "#{path} is above #{HookScript::SERVE_LIMIT} bytes now; run again" if bytes.bytesize > HookScript::SERVE_LIMIT

      bytes
    rescue SystemCallError => e
      raise SettingsChanged, "#{path} is unreadable: #{e.message}"
    end

    def backup(plan)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      dir = File.join(Rplugin::Paths.state_home, "ordonnateur", "backups")
      FileUtils.mkdir_p(dir, mode: 0o700)
      base = File.join(dir, "#{stamp}-script-#{File.basename(plan.path)}")
      target = base
      counter = 1
      while File.exist?(target)
        target = "#{base}.#{counter}"
        counter += 1
      end
      source = File.stat(plan.path)
      mode = (source.mode & 0o7777) & 0o600
      File.open(target, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, mode) do |out|
        File.open(plan.path, "rb") { |input| IO.copy_stream(input, out) }
      end
      File.utime(source.atime, source.mtime, target)
      target
    end

    def announce(plan, sha_after)
      HookScript::Trail.emit(
        @ports, "ordonnateur.hook.edited",
        {
          "harness" => plan.harness, "scope" => plan.scope, "hook_id" => plan.hook_id, "path" => plan.path,
          "sha_before" => plan.sha_before, "sha_after" => sha_after, "plan_id" => plan.plan_id, "via" => @via
        }
      )
      HookScript::Trail.record(
        @ports, kind: "edited",
        hook: Subject.new(
          id: plan.hook_id, harness: plan.harness, scope: plan.scope, plugin: nil, event: plan.event,
          source_file: plan.source_file
        ),
        via: @via, at: @at,
        detail: { "path" => plan.path, "sha_before" => plan.sha_before, "sha_after" => sha_after, "plan_id" => plan.plan_id }
      )
    end
  end
end
