#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "delegate"

module Ordonnateur
  class SafeOutput < SimpleDelegator
    def self.clean(text)
      text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").gsub(/[\p{Cc}&&[^\n\t]]/, "?")
    end

    def puts(*items)
      super(*items.flatten.map { |item| self.class.clean(item) })
    end

    def print(*items)
      super(*items.map { |item| self.class.clean(item) })
    end

    def <<(item)
      super(self.class.clean(item))
    end

    def printf(template, *items)
      write(format(template, *items))
    end

    def write(*items)
      super(*items.map { |item| self.class.clean(item) })
    end
  end
end
