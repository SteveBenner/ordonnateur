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
require_relative "harnesses/claude_code"

module Ordonnateur
  class SettingsPlan
    Entry = Struct.new(:path, :before, :after, :mode, keyword_init: true)
    Plan = Struct.new(:scope, :path, :before, :after, :sha, :mode, :verdicts, :notes, :widening, :ops, keyword_init: true) do
      def entries
        [Entry.new(path: path, before: before, after: after, mode: mode)]
      end
    end
    Checked = Struct.new(:ops, :errors, :widening, keyword_init: true)

    ALLOWED_PATHS = %w[
      permissions.allow permissions.ask permissions.deny permissions.additionalDirectories env model effortLevel
      enabledPlugins cleanupPeriodDays
    ].freeze
    LIST_KEYS = %w[allow ask deny additionalDirectories].freeze
    SCALAR_KEYS = %w[model effortLevel cleanupPeriodDays].freeze
    OPS = %w[set unset add remove].freeze
    REFUSED_ENV_NAMES = %w[PATH RUBYOPT RUBYLIB NODE_OPTIONS PYTHONPATH].freeze
    REFUSED_ENV_PREFIXES = %w[LD_ DYLD_].freeze
    REFUSED_ENV_SUFFIXES = %w[_BASE_URL _URL _HOST].freeze
    CREDENTIAL_NAME = /token|secret|password|passphrase|credential|cookie|auth|key/i.freeze
    WHOLE_TOOL = /\A[A-Za-z_][\w.:-]*\(\s*:?\*+\s*\)\z/.freeze
    BARE_TOOL = /\A[A-Za-z_][\w.:*-]*\z/.freeze
    SPECIFIC_MCP = /\Amcp__[\w-]+__[\w-]+\z/.freeze
    VALUE_LIMIT = 500
    OPS_LIMIT = 20

    attr_reader :scope, :path, :root

    def initialize(scope:, project: nil, ports:, cwd: Dir.pwd)
      raise Usage, "scope must be user or local" unless %w[user local].include?(scope)

      @scope = scope
      @ports = ports
      @cwd = cwd
      @root = Harnesses::ClaudeCode.project_root(project)
      @path = Harnesses::ClaudeCode.settings_path(scope, @root)
    end

    def self.check_ops(ops, guard_plugins: [])
      errors = []
      widening = false
      normalized = []
      list = ops.is_a?(Array) ? ops : nil
      errors << "ops must be a list" if list.nil?
      errors << "ops must hold between 1 and #{OPS_LIMIT} operations" if list && (list.empty? || list.length > OPS_LIMIT)
      Array(list).first(OPS_LIMIT).each_with_index do |raw, index|
        op, problems, wide = check_op(raw, guard_plugins)
        problems.each { |problem| errors << "op #{index + 1}: #{problem}" }
        normalized << op if op && problems.empty?
        widening ||= wide
      end
      Checked.new(ops: normalized, errors: errors, widening: widening)
    end

    def self.check_op(raw, guard_plugins)
      return [nil, ["is not an object"], false] unless raw.is_a?(Hash)

      item = raw.transform_keys(&:to_s)
      name = item["op"].to_s
      path = item["path"]
      return [nil, ["op must be one of #{OPS.join(', ')}"], false] unless OPS.include?(name)
      unless path.is_a?(Array) && !path.empty? && path.length <= 3 && path.all? { |part| part.is_a?(String) && !part.empty? }
        return [nil, ["path must be a list of one to three names"], false]
      end

      problems = []
      problems << "bypassPermissions is refused" if JSON.generate([path, item["value"]]).include?("bypassPermissions")
      problems << "#{path.join('.')}: a key ending in Helper is refused" if path.any? { |part| part.end_with?("Helper") }
      kind = kind_of(path)
      problems << refusal_for(path) if kind.nil?
      value = item["value"]
      wide = false
      if kind && problems.empty?
        found, wide = check_value(kind, name, path, value, guard_plugins)
        problems.concat(found)
      end
      op = { "op" => name, "path" => path }
      op["value"] = value unless name == "unset"
      [op, problems, wide]
    end

    def self.kind_of(path)
      return :list if path.length == 2 && path[0] == "permissions" && LIST_KEYS.include?(path[1])
      return :env if path.length == 2 && path[0] == "env"
      return :plugin if path.length == 2 && path[0] == "enabledPlugins"
      return :scalar if path.length == 1 && SCALAR_KEYS.include?(path[0])

      nil
    end

    def self.refusal_for(path)
      joined = path.join(".")
      return "permissions.defaultMode is refused" if joined == "permissions.defaultMode"
      return "#{joined} is refused; hooks are changed only by untangle healers" if path[0] == "hooks"

      "#{joined} is not an allowed path; allowed: #{ALLOWED_PATHS.join(', ')}"
    end

    def self.check_value(kind, name, path, value, guard_plugins)
      case kind
      when :list then check_list(name, path, value)
      when :env then [check_env(name, path[1], value), false]
      when :plugin then check_plugin(name, path[1], value, guard_plugins)
      else [check_scalar(name, path[0], value), false]
      end
    end

    def self.check_list(name, path, value)
      key = path[1]
      problems = []
      entries = []
      case name
      when "add", "remove"
        problems << "#{name} needs a text value" unless value.is_a?(String) && !value.strip.empty? && value.length <= VALUE_LIMIT
        entries = [value] if problems.empty?
      when "set"
        valid = value.is_a?(Array) && value.length <= 100 &&
                value.all? { |item| item.is_a?(String) && !item.strip.empty? && item.length <= VALUE_LIMIT }
        problems << "set needs a list of text values" unless valid
        entries = value if valid
      else
        problems << "unset takes no value" unless value.nil?
      end
      if key == "allow" && %w[add set].include?(name)
        entries.each { |entry| problems << "#{entry.inspect} allows a whole tool and is refused" if whole_tool?(entry) }
      end
      wide = (%w[allow additionalDirectories].include?(key) && %w[add set].include?(name)) ||
             (%w[ask deny].include?(key) && %w[remove unset set].include?(name))
      [problems, wide]
    end

    def self.whole_tool?(entry)
      text = entry.strip
      return true if text == "*" || WHOLE_TOOL.match?(text)
      return false if text.include?("(")

      !SPECIFIC_MCP.match?(text) && BARE_TOOL.match?(text)
    end

    def self.check_env(name, variable, value)
      problems = []
      problems << "env supports set and unset only" unless %w[set unset].include?(name)
      if CREDENTIAL_NAME.match?(variable) || REFUSED_ENV_NAMES.include?(variable) ||
         REFUSED_ENV_PREFIXES.any? { |prefix| variable.start_with?(prefix) } ||
         REFUSED_ENV_SUFFIXES.any? { |suffix| variable.end_with?(suffix) }
        problems << "env #{variable} is refused"
      end
      if name == "set" && !(value.is_a?(String) && value.length <= VALUE_LIMIT)
        problems << "env set needs a text value"
      end
      problems << "unset takes no value" if name == "unset" && !value.nil?
      problems
    end

    def self.check_plugin(name, plugin, value, guard_plugins)
      problems = []
      wide = false
      case name
      when "set"
        problems << "enabledPlugins set needs true or false" unless [true, false].include?(value)
        wide = value == true
        off = value == false
      when "unset"
        problems << "unset takes no value" unless value.nil?
        off = true
      else
        problems << "enabledPlugins supports set and unset only"
      end
      problems << "#{plugin} holds a guard or protected hook and cannot be turned off" if off && guard_plugins.include?(plugin)
      [problems, wide]
    end

    def self.check_scalar(name, key, value)
      return ["#{key} supports set and unset only"] unless %w[set unset].include?(name)
      return (value.nil? ? [] : ["unset takes no value"]) if name == "unset"

      if key == "cleanupPeriodDays"
        value.is_a?(Integer) && value.between?(1, 3650) ? [] : ["cleanupPeriodDays needs a whole number from 1 to 3650"]
      else
        value.is_a?(String) && !value.strip.empty? && value.length <= 100 ? [] : ["#{key} needs a short text value"]
      end
    end

    def self.verdict_problem(verdicts)
      verdicts.each do |path, verdict|
        case verdict[:verdict]
        when "deny" then return "polispec denies writing #{path}: #{verdict[:reason]} (#{verdict[:rule_id]})"
        when "warn" then return "polispec warns on writing #{path}: #{verdict[:reason]}"
        end
      end
      nil
    end

    def self.backup(paths, label)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      dir = File.join(Rplugin::Paths.state_home, "ordonnateur", "backups")
      FileUtils.mkdir_p(dir)
      paths.filter_map do |path|
        next unless File.file?(path)

        target = File.join(dir, "#{stamp}-#{label}-#{File.basename(path)}")
        counter = 1
        while File.exist?(target)
          target = File.join(dir, "#{stamp}-#{label}-#{File.basename(path)}.#{counter}")
          counter += 1
        end
        FileUtils.cp(path, target, preserve: true)
        target
      end
    end

    def self.restore(entries)
      entries.each do |entry|
        current = Harnesses::ClaudeCode.read_text(entry.path)
        unless Digest::SHA256.hexdigest(current.to_s) == Digest::SHA256.hexdigest(entry.after.to_s)
          raise SettingsChanged, "#{entry.path} changed after it was written; not restored"
        end
      end
      backup(entries.map(&:path), "restore")
      entries.each do |entry|
        if entry.before.nil?
          File.delete(entry.path) if File.exist?(entry.path)
        else
          Harnesses::ClaudeCode.write_file(entry.path, entry.before, mode: entry.mode || 0o600)
        end
      end
      true
    end

    def plan_ops(ops, guard_plugins: [])
      checked = self.class.check_ops(ops, guard_plugins: guard_plugins)
      raise Refused, "refused:\n#{checked.errors.map { |line| "  #{line}" }.join("\n")}" unless checked.errors.empty?

      source = read
      data = copy(source.data)
      checked.ops.each { |op| apply_op(data, op) }
      finish(source, data, ops: checked.ops, widening: checked.widening)
    end

    def plan_hook_edit(kind, hook)
      source = read
      data = copy(source.data)
      groups, group_index, handler_index = locate(data, hook)
      group = groups[group_index]
      case kind
      when :drop_matcher then group.delete("matcher")
      when :remove_handler
        group["hooks"].delete_at(handler_index)
        if group["hooks"].empty?
          groups.delete_at(group_index)
          data["hooks"].delete(hook.event) if groups.empty?
        end
      else
        raise Usage, "unknown hook edit #{kind}"
      end
      finish(source, data)
    end

    def changed?(plan)
      plan.after != plan.before
    end

    def apply(plan)
      return false unless changed?(plan)

      problem = self.class.verdict_problem(plan.verdicts)
      raise Refused, "#{problem}; ordonnateur never proceeds on a warn or deny" if problem

      current = Harnesses::ClaudeCode.read_text(plan.path)
      raise SettingsChanged, "settings changed while planning; run again" unless Digest::SHA256.hexdigest(current.to_s) == plan.sha

      @backups = self.class.backup([plan.path], plan.scope)
      Harnesses::ClaudeCode.write_file(plan.path, plan.after, mode: plan.mode || 0o600)
      true
    end

    def backups
      @backups || []
    end

    def render(plan)
      lines = []
      plan.notes.each { |note| lines << "note: #{note}" }
      plan.verdicts.each do |path, verdict|
        lines << "policy: write #{path}: #{verdict[:verdict]}#{verdict[:rule_id] ? " (#{verdict[:rule_id]})" : ''} #{verdict[:reason]}".rstrip
      end
      lines << diff(plan.path, plan.before, plan.after)
      lines.reject { |line| line.nil? || line.empty? }.join("\n")
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

    private

    def read
      Harnesses::ClaudeCode.read_source(@scope, @path)
    end

    def copy(value)
      JSON.parse(JSON.generate(value))
    end

    def finish(source, data, ops: nil, widening: false)
      after = data == source.data ? source.text : serialize(data, source.text)
      plan = Plan.new(
        scope: @scope, path: @path, before: source.text, after: after,
        sha: Digest::SHA256.hexdigest(source.text.to_s), mode: Harnesses::ClaudeCode.mode_of(@path),
        notes: [], widening: widening, ops: ops
      )
      plan.verdicts = verdicts_for(plan)
      plan
    end

    def serialize(data, before)
      json = JSON.pretty_generate(data)
      before.nil? || before.end_with?("\n") ? "#{json}\n" : json
    end

    def verdicts_for(plan)
      return [] unless changed?(plan)

      verdict = @ports.policy.judge(
        tool_name: "Write", tool_input: { "file_path" => plan.path, "content" => plan.after.to_s }, cwd: @cwd
      )
      [[plan.path, verdict]]
    end

    def locate(data, hook)
      groups = data.dig("hooks", hook.event)
      raise Refused, "#{hook.id} is no longer in #{@path}" unless groups.is_a?(Array)

      key = Canonical.json(hook.hook)
      matches = []
      groups.each_with_index do |group, group_index|
        next unless group.is_a?(Hash) && group["hooks"].is_a?(Array) && group["matcher"] == hook.matcher

        group["hooks"].each_with_index do |handler, handler_index|
          matches << [group_index, handler_index] if handler.is_a?(Hash) && Canonical.json(handler) == key
        end
      end
      raise Refused, "#{hook.id} is no longer in #{@path}" if matches.empty?
      raise Refused, "#{hook.id} appears more than once in #{@path}; edit it by hand" if matches.length > 1

      [groups, matches.first[0], matches.first[1]]
    end

    def apply_op(data, op)
      keys = op["path"]
      leaf = keys.last
      parent = keys[0..-2].reduce(data) do |node, key|
        node[key] = {} unless node.key?(key)
        raise Refused, "#{key} in #{@path} is not an object" unless node[key].is_a?(Hash)

        node[key]
      end
      case op["op"]
      when "set" then parent[leaf] = copy([op["value"]]).first
      when "unset" then parent.delete(leaf)
      when "add" then list_for(parent, leaf, true) << op["value"] unless list_for(parent, leaf, true).include?(op["value"])
      when "remove" then (list = list_for(parent, leaf, false)) && list.delete(op["value"])
      end
      prune(data, keys[0..-2]) if %w[unset remove].include?(op["op"])
    end

    def list_for(parent, leaf, create)
      parent[leaf] = [] if create && !parent.key?(leaf)
      list = parent[leaf]
      return nil if list.nil? && !create
      raise Refused, "#{leaf} in #{@path} is not a list" unless list.is_a?(Array)

      list
    end

    def prune(data, keys)
      keys.length.downto(1) do |depth|
        parent = keys[0...depth - 1].reduce(data) { |node, key| node[key] }
        node = parent[keys[depth - 1]]
        parent.delete(keys[depth - 1]) if node.is_a?(Hash) && node.empty?
      end
    end
  end
end
