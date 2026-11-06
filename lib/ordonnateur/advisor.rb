#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "fileutils"
require "json"

require_relative "redact"
require_relative "author/standalone"

module Ordonnateur
  class Advisor
    PACKET_BYTES = 60_000
    ATTEMPTS = 2
    BACKOFF_S = (1.0..4.0)
    LOCK_WAIT_S = 5
    LOCK_POLL_S = 0.2
    TURNS_PER_MINUTE = 10
    WINDOW_S = 60
    ROOT = File.expand_path("../..", __dir__)
    EXTENSION_PREFIX = "Rplugin::Adapters::"

    def initialize(ports:, settings:, root: ROOT)
      @ports = ports
      @settings = settings
      @root = root
    end

    def ask(system:, prompt:)
      refusal = refusal_for(system, prompt)
      return off(refusal) if refusal

      backend = @settings.get("advisor.backend").to_s
      port = backend == "extension" ? extension_port : harness_port
      return off(port) if port.is_a?(String)

      with_lock { attempt(port, backend, system.to_s, prompt.to_s) }
    end

    def self.parse_json(text)
      body = text.to_s.strip
      candidates = [body]
      fenced = body.match(/```(?:json)?\s*(.*?)```/m)
      candidates << fenced[1].strip if fenced
      first = body.index("{")
      last = body.rindex("}")
      candidates << body[first..last] if first && last && last > first
      candidates.each do |candidate|
        data = decode(candidate)
        return data if data.is_a?(Hash)
      end
      nil
    end

    def self.decode(candidate)
      JSON.parse(candidate)
    rescue JSON::ParserError
      nil
    end

    def self.fit(tree, limit)
      [40, 20, 10, 5, 2, 0].each do |keep|
        candidate = shrink(tree, keep)
        return candidate if JSON.generate(candidate).bytesize <= limit
      end
      shrink(tree, 0)
    end

    def self.shrink(value, keep)
      case value
      when Hash then value.transform_values { |item| shrink(item, keep) }
      when Array
        kept = value.first(keep).map { |item| shrink(item, keep) }
        value.length > keep ? kept + ["+#{value.length - keep} more"] : kept
      when String then value.length > 300 ? "#{value[0, 300]}..." : value
      else value
      end
    end

    private

    def refusal_for(system, prompt)
      return "ORDONNATEUR_ADVISOR_DISABLED=1 turns the model off, so this run uses no model" if ENV["ORDONNATEUR_ADVISOR_DISABLED"] == "1"
      unless ENV["ORDONNATEUR_NESTED"].to_s.empty?
        return "ORDONNATEUR_NESTED is set, so this run is already inside a model call"
      end

      size = system.to_s.bytesize + prompt.to_s.bytesize
      size > PACKET_BYTES ? "the packet is #{size} bytes, over the #{PACKET_BYTES} byte limit" : nil
    end

    def failure(reason)
      { ok: false, reason: Redact.text(reason.to_s)[0, 400] }
    end

    def off(reason)
      { ok: false, off: true, reason: reason.to_s[0, 400] }
    end

    def harness_port
      Author::Standalone.new(plugin_id: "ordonnateur", fallback: nil, root: @root)
    end

    def extension_port
      names = Array(@ports.chain("author"))
      unless names.any? { |name| name.to_s.start_with?(EXTENSION_PREFIX) }
        return "advisor.backend is extension, but no extension adapter backs the author port; install the extension or set advisor.backend to harness"
      end

      @ports.author
    rescue Rplugin::PortUnavailable => e
      e.message
    end

    def state_dir
      File.join(Rplugin::Paths.state_home, "ordonnateur")
    end

    def with_lock
      FileUtils.mkdir_p(state_dir)
      File.open(File.join(state_dir, "advisor.lock"), File::RDWR | File::CREAT, 0o600) do |file|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOCK_WAIT_S
        until file.flock(File::LOCK_EX | File::LOCK_NB)
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            return failure("another model call holds the lock; waited #{LOCK_WAIT_S} seconds")
          end

          sleep(LOCK_POLL_S)
        end
        yield
      end
    end

    def attempt(port, backend, system, prompt)
      reason = nil
      ATTEMPTS.times do |index|
        sleep(rand(BACKOFF_S)) if index.positive?
        over = take_turn
        return failure(over) if over

        begin
          text = converse(port, backend, system, prompt)
          return { ok: true, text: text } unless text.strip.empty?

          reason = "the model returned no text"
        rescue StandardError => e
          reason = e.message.to_s.empty? ? e.class.name : e.message
        end
      end
      failure(reason)
    end

    def converse(port, backend, system, prompt)
      session = port.open({ system: system, backend: backend })
      begin
        result = port.turn(session, prompt)
      ensure
        port.close(session)
      end
      value = result.is_a?(Hash) ? (result[:text] || result["text"]) : result
      value.to_s
    end

    def take_turn
      path = File.join(state_dir, "advisor-turns.json")
      now = Time.now.to_f
      stamps = read_turns(path).select { |stamp| now - stamp < WINDOW_S }
      return "the model call rate of #{TURNS_PER_MINUTE} per minute is reached" if stamps.length >= TURNS_PER_MINUTE

      stamps << now
      File.write(path, JSON.generate(stamps))
      nil
    end

    def read_turns(path)
      return [] unless File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Array) ? data.grep(Numeric) : []
    rescue JSON::ParserError
      []
    end
  end
end
