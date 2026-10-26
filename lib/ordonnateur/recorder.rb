#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "time"

module Ordonnateur
  module Recorder
    module_function

    def script_path
      home = ENV["RPLUGIN_BIN_HOME"]
      base = home && !home.empty? ? home : File.join(Dir.home, ".local", "bin")
      installed = File.join(File.expand_path(base), "ordonnateur")
      File.executable?(installed) ? installed : File.expand_path($PROGRAM_NAME)
    end

    def spawn_detached(record, script: script_path)
      return if ENV["ORDONNATEUR_RECORD_DISABLED"] == "1"

      reader, writer = IO.pipe
      pid = Process.spawn(script, "record", in: reader, out: File::NULL, err: File::NULL, pgroup: true)
      reader.close
      writer.write(JSON.generate(record))
      writer.close
      Process.detach(pid)
    rescue SystemCallError, IOError
      nil
    end

    def stream_for(record)
      "runs-#{Time.parse(record["at"]).utc.strftime('%Y-%m')}"
    end

    def completed_payload(record)
      payload = {
        "harness" => record["harness"], "scope" => record["scope"], "event" => record["event"],
        "total_ms" => record["total_ms"], "verdict" => record["verdict"],
        "members" => record["members"].map { |member| member.slice("id", "ms", "outcome") }
      }
      payload["source"] = "fire" if record["source"] == "fire"
      payload
    end

    def emit_completed(record, ports, settings)
      return unless settings.on?("events.runs")

      kind = record["source"] == "fire" ? "ordonnateur.fire.completed" : "ordonnateur.run.completed"
      ports.events.emit(kind, completed_payload(record))
    end

    def store(record, ports, settings)
      ports.state.append(stream_for(record), record)
      emit_completed(record, ports, settings)
      require_relative "alerts"
      Alerts.check(record, ports, settings)
      if record.dig("verdict", "decision") == "failure"
        ports.events.emit(
          "ordonnateur.run.failed",
          { "harness" => record["harness"], "scope" => record["scope"], "event" => record["event"], "card" => record["card"] }
        )
      end
      record["members"].each do |member|
        next unless %w[error timeout].include?(member["outcome"])

        ports.events.emit(
          "ordonnateur.member.failed",
          { "harness" => record["harness"], "scope" => record["scope"], "event" => record["event"],
            "id" => member["id"], "outcome" => member["outcome"], "exit" => member["exit"], "ms" => member["ms"] }
        )
      end
      nil
    end
  end
end
