#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "time"

require_relative "timings"

module Ordonnateur
  module Alerts
    WINDOW_S = 6 * 3600

    module_function

    def check(record, ports, settings, now: Time.now.utc)
      return unless record["source"] == "dispatch"

      threshold = settings.get("alerts.failures")
      return if threshold.zero?

      failed = record["members"].select { |member| Timings::FAILED.include?(member["outcome"]) }
      return if failed.empty?

      history = Timings.records(ports, 2).sort_by { |item| item["at"].to_s }
      failed.each { |member| alert_member(record, member, history, threshold, ports, now) }
    end

    def alert_member(record, member, history, threshold, ports, now)
      runs = history.select { |item| item["source"] == "dispatch" }.flat_map do |item|
        item["members"].select { |entry| entry["id"] == member["id"] && Timings::RAN.include?(entry["outcome"]) }
      end
      recent = runs.last(threshold)
      return unless recent.length >= threshold && recent.all? { |entry| Timings::FAILED.include?(entry["outcome"]) }

      last = ports.state.read("alerts").select { |item| item["member"] == member["id"] }.last
      return if last && Time.parse(last["at"]) > now - WINDOW_S

      short = member["id"].split(":").last
      Rplugin::Notify.deliver(
        {
          source: "ordonnateur",
          title: "ordonnateur: #{short} failed #{threshold} runs in a row",
          body: "#{record['event']} in #{record['scope']} scope: #{member['outcome']}, exit #{member['exit'].inspect}: " \
                "#{member['stderr_head']}. Run ordonnateur fire #{short} to test it.",
          urgency: "normal"
        },
        ports: ports
      )
      ports.state.append("alerts", { "at" => now.iso8601, "member" => member["id"], "event" => record["event"] })
    end
  end
end
