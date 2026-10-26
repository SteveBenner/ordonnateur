#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "time"

module Ordonnateur
  module Timings
    RAN = %w[ok block deny ask defer allow error timeout].freeze
    FAILED = %w[error timeout].freeze

    module_function

    def streams(months, now = Time.now.utc)
      base = now.year * 12 + now.month - 1
      (0...months).map do |back|
        index = base - back
        format("runs-%04d-%02d", index / 12, index % 12 + 1)
      end
    end

    def records(ports, months)
      streams(months).flat_map { |stream| ports.state.read(stream) }
    end

    def percentile(sorted, percent)
      return 0 if sorted.empty?

      sorted[[(percent / 100.0 * sorted.length).ceil, 1].max - 1]
    end

    def rows(records, event: nil, slow_ms: 2000)
      groups = Hash.new { |hash, key| hash[key] = [] }
      records.each do |record|
        next if event && record["event"] != event

        record["members"].each do |member|
          next unless RAN.include?(member["outcome"])

          groups[[record["harness"], record["event"], member["id"]]] << member
        end
      end
      groups.map do |(harness, name, id), members|
        times = members.map { |member| member["ms"].to_i }.sort
        timeout_s = members.map { |member| member["timeout_s"] }.compact.max
        p95 = percentile(times, 95)
        max = times.last
        {
          "harness" => harness, "event" => name, "id" => id, "runs" => members.length,
          "p50" => percentile(times, 50), "p95" => p95, "max" => max,
          "failures" => members.count { |member| FAILED.include?(member["outcome"]) },
          "timeout_s" => timeout_s,
          "slow" => p95 > slow_ms && members.length >= 5,
          "near_timeout" => !timeout_s.nil? && max >= timeout_s * 800
        }
      end.sort_by { |row| [row["harness"].to_s, row["event"].to_s, row["id"].to_s] }
    end
  end
end
