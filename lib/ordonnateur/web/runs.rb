#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"
require "stringio"
require "time"
require "securerandom"

module Ordonnateur
  module Web
    class Runs
      KEEP = 20
      TTL = 3600

      Record = Struct.new(:id, :verb, :status, :started_at, :finished_at, :exit, :report, :error, keyword_init: true)

      def initialize(logger:)
        @logger = logger
        @records = []
        @lock = Mutex.new
      end

      def start(verb, &runner)
        record = nil
        @lock.synchronize do
          purge
          active = @records.find { |item| item.status == "running" }
          if active
            raise Failure.new(409, "run_active", "another run is still going; wait for it to finish", { run_id: active.id })
          end

          record = Record.new(id: SecureRandom.hex(8), verb: verb, status: "running", started_at: Time.now.utc)
          @records << record
        end
        Thread.new { execute(record, runner) }
        { "run_id" => record.id, "verb" => record.verb, "status" => "running", "started_at" => record.started_at.iso8601 }
      end

      def overview
        @lock.synchronize do
          purge
          active = @records.find { |item| item.status == "running" }
          latest = %w[untangle plan].to_h do |verb|
            newest = @records.select { |item| item.verb == verb }.max_by(&:started_at)
            [verb, newest&.id]
          end
          { "active" => active && summary(active), "latest" => latest }
        end
      end

      def fetch(id)
        @lock.synchronize do
          purge
          record = @records.find { |item| item.id == id }
          raise Failure.new(404, "not_found", "no such run") unless record

          full(record)
        end
      end

      private

      def execute(record, runner)
        out = StringIO.new
        code = runner.call(out)
        report = JSON.parse(out.string)
        finish(record, "done", exit: code, report: report)
      rescue Ordonnateur::Error => e
        finish(record, "failed", exit: e.exit_code, error: e.message)
      rescue StandardError => e
        @logger.error("run #{record.id} #{e.class}: #{e.message}")
        finish(record, "failed", exit: 1, error: "internal error")
      end

      def finish(record, status, exit:, report: nil, error: nil)
        @lock.synchronize do
          record.exit = exit
          record.report = report
          record.error = error
          record.finished_at = Time.now.utc
          record.status = status
        end
      end

      def purge
        limit = Time.now.utc - TTL
        @records.delete_if { |item| item.status != "running" && item.finished_at < limit }
        finished = @records.select { |item| item.status != "running" }.sort_by(&:started_at)
        room = KEEP - @records.count { |item| item.status == "running" }
        drop = finished.length - [room, 0].max
        finished.first(drop).each { |item| @records.delete(item) } if drop.positive?
      end

      def summary(record)
        { "run_id" => record.id, "verb" => record.verb, "status" => record.status, "started_at" => record.started_at.iso8601 }
      end

      def full(record)
        summary(record).merge(
          "finished_at" => record.finished_at&.iso8601, "exit" => record.exit, "report" => record.report,
          "error" => record.error
        )
      end
    end
  end
end
