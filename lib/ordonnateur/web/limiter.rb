#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Ordonnateur
  module Web
    class Limiter
      LIMIT = 30
      WINDOW = 60

      def initialize
        @lock = Mutex.new
      end

      def take(session, now = Time.now.to_f)
        @lock.synchronize do
          session.mutations.reject! { |stamp| now - stamp >= WINDOW }
          if session.mutations.length >= LIMIT
            wait = (WINDOW - (now - session.mutations.first)).ceil
            return [false, [wait, 1].max]
          end
          session.mutations << now
          [true, 0]
        end
      end
    end
  end
end
