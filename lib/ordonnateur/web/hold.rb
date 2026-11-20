#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "openssl"
require "securerandom"
require "time"

module Ordonnateur
  module Web
    class Hold
      DELAY = 3.0
      WINDOW = 60.0
      MAX_HOLDS = 200

      Entry = Struct.new(:hold_id, :not_before, :expires_at, keyword_init: true)

      def initialize(clock: -> { Time.now.to_f })
        @clock = clock
        @entries = {}
        @lock = Mutex.new
      end

      def start(session, plan_id)
        now = @clock.call
        entry = Entry.new(hold_id: "hd_#{SecureRandom.hex(8)}", not_before: now + DELAY, expires_at: now + WINDOW)
        @lock.synchronize do
          purge(now)
          key = key_for(session, plan_id)
          @entries.delete(key)
          @entries.shift while @entries.length >= MAX_HOLDS
          @entries[key] = entry
        end
        {
          "hold_id" => entry.hold_id, "not_before" => Time.at(entry.not_before).utc.iso8601(3),
          "expires_at" => Time.at(entry.expires_at).utc.iso8601(3)
        }
      end

      def redeem!(session, plan_id, hold_id)
        now = @clock.call
        entry = @lock.synchronize { @entries.delete(key_for(session, plan_id)) }
        if hold_id.nil? || hold_id.to_s.empty?
          raise Failure.new(422, "hold_required", "this plan needs a hold: start one and hold for three seconds")
        end
        unless entry && same_hold?(entry.hold_id, hold_id)
          raise Failure.new(422, "hold_unknown", "no such hold for this plan in this session, or it was already used")
        end
        raise Failure.new(422, "hold_expired", "the hold ran out; hold the button again") if now > entry.expires_at
        raise Failure.new(422, "hold_early", "the hold is not three seconds old yet") if now < entry.not_before

        true
      end

      private

      def same_hold?(expected, given)
        given = given.to_s
        given.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(expected, given)
      end

      def key_for(session, plan_id)
        [session.token, plan_id]
      end

      def purge(now)
        @entries.delete_if { |_, entry| now > entry.expires_at + WINDOW }
      end
    end
  end
end
