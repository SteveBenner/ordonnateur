#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module Ordonnateur
  module Provenance
    module Event
      KINDS = %w[first_seen changed disappeared reappeared enabled disabled edited deleted].freeze
      BASES = %w[observed ordonnateur plugin_record file_mtime].freeze
      VIAS = %w[cli web watch tick].freeze
      FIELDS = %w[id at kind hook_id harness scope plugin event source_file basis via detail].freeze

      module_function

      def build(kind:, hook_id:, harness: nil, scope: nil, plugin: nil, event: nil, source_file: nil,
                basis: "observed", via: nil, detail: nil, at: Time.now.utc)
        {
          "id" => SecureRandom.hex(8),
          "at" => iso(at),
          "kind" => kind.to_s,
          "hook_id" => hook_id.to_s,
          "harness" => harness,
          "scope" => scope,
          "plugin" => plugin,
          "event" => event,
          "source_file" => source_file,
          "basis" => basis.to_s,
          "via" => via&.to_s,
          "detail" => detail || {}
        }
      end

      def normalize(raw)
        return nil unless raw.respond_to?(:to_h)

        given = raw.to_h
        stamp = given["at"] || given[:at]
        data = JSON.parse(JSON.generate(given))
        return nil unless KINDS.include?(data["kind"]) && !data["hook_id"].to_s.empty?

        data["id"] = SecureRandom.hex(8) unless data["id"].to_s.match?(/\A\h{16}\z/)
        data["at"] = iso(stamp.is_a?(Time) ? stamp : (data["at"].nil? ? Time.now.utc : data["at"]))
        data["basis"] = "observed" unless BASES.include?(data["basis"])
        data["via"] = nil unless VIAS.include?(data["via"])
        data["detail"] = {} unless data["detail"].is_a?(Hash)
        FIELDS.each_with_object({}) { |name, out| out[name] = data[name] }
      rescue ArgumentError => e
        warn("ordonnateur: provenance event rejected, its time is not ISO 8601 (#{e.message.to_s[0, 120]})")
        nil
      rescue JSON::JSONError, TypeError, JSON::GeneratorError
        nil
      end

      def iso(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(3)
      end

      def time_of(value)
        return value.utc if value.is_a?(Time)

        Time.iso8601(value.to_s).utc
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
