#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "digest"
require "json"
require "time"

require_relative "model"
require_relative "inventory"
require_relative "lint"
require_relative "timings"
require_relative "harnesses/claude_code"
require_relative "harnesses/codex"
require_relative "harnesses/hermes"

module Ordonnateur
  class Watch
    def initialize(ports:, settings:)
      @ports = ports
      @settings = settings
    end

    def fingerprint(inventory)
      files = []
      files.concat(Harnesses::ClaudeCode.watch_files(inventory.claude)) if inventory.claude
      files.concat(inventory.cards.values.map { |entry| entry[:path] })
      files.concat(Harnesses::Codex.watch_files(inventory.codex)) if inventory.codex
      hermes = hermes_lines(inventory)
      files.concat(Harnesses::Hermes.watch_files(inventory.hermes)) unless hermes.empty?
      lines = files.uniq.sort.map do |path|
        digest = File.file?(path) ? Digest::SHA256.file(path).hexdigest : "MISSING"
        "#{path}\0#{digest}"
      end
      lines.concat(hermes)
      Digest::SHA256.hexdigest(lines.join("\n"))
    rescue SystemCallError => e
      raise HarnessFileError, "watch could not read a configuration file: #{e.message}"
    end

    def hermes_lines(inventory)
      return [] unless inventory.hermes

      hooks = inventory.hooks.select { |hook| hook.harness == "hermes" }
      present = [Harnesses::Hermes.config_path, Harnesses::Hermes.allowlist_path].any? { |path| File.file?(path) }
      return [] unless present || !hooks.empty?

      hooks.map { |hook| "#{hook.id}\0#{hook.status}" }.sort
    end

    def call(options, out)
      return 0 unless @settings.on?("watch.enabled")

      inventory = Inventory.load_full(harness: "all", project: options[:project], policy: @ports.policy)
      print = fingerprint(inventory)
      previous = @ports.state.read("watch").last
      return 0 if previous && previous["fingerprint"] == print

      slow = @settings.get("lint.slow_ms")
      rows = Timings.rows(Timings.records(@ports, 2), slow_ms: slow)
      findings = Lint.run(inventory, rows: rows, slow_ms: slow).select { |item| Lint::FAILING.include?(item["severity"]) }
      by_key = findings.to_h { |item| ["#{item['code']}|#{item['hook']}", item] }
      if previous.nil?
        @ports.state.append("watch", { "at" => Time.now.utc.iso8601, "fingerprint" => print, "keys" => by_key.keys })
        @ports.events.emit("ordonnateur.watch.changed", { "new" => [], "resolved" => [], "baseline" => true })
        return 0
      end
      previous_keys = previous["keys"]
      added = by_key.keys - previous_keys
      resolved = previous_keys - by_key.keys
      notify(added.map { |key| by_key[key] }) unless added.empty?
      @ports.state.append("watch", { "at" => Time.now.utc.iso8601, "fingerprint" => print, "keys" => by_key.keys })
      @ports.events.emit("ordonnateur.watch.changed", { "new" => added, "resolved" => resolved })
      report(added.map { |key| by_key[key] }, resolved, out, options)
      0
    end

    def notify(new_findings)
      urgency = new_findings.any? { |item| item["severity"] == "error" } ? "critical" : "normal"
      lines = new_findings.first(3).map { |item| item["message"] } + ["run ordonnateur lint for all"]
      Rplugin::Notify.deliver(
        { source: "ordonnateur", title: "ordonnateur: #{new_findings.length} new hook finding(s)",
          body: lines.join("\n"), urgency: urgency },
        ports: @ports
      )
    end

    def report(added, resolved, out, options)
      return if options[:quiet]

      if options[:json]
        out.puts JSON.pretty_generate({ "new" => added, "resolved" => resolved })
        return
      end
      added.each { |item| out.puts "new #{item['code']} #{item['hook']}: #{item['message']}" }
      resolved.each { |key| out.puts "resolved #{key}" }
    end
  end
end
