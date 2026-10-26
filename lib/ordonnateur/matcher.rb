#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Ordonnateur
  module Matcher
    SIMPLE = /\A[A-Za-z0-9_\- ,|]+\z/.freeze

    module_function

    def all?(matcher)
      matcher.nil? || matcher == "" || matcher == "*"
    end

    def simple?(matcher)
      matcher.is_a?(String) && SIMPLE.match?(matcher)
    end

    def alternatives(matcher)
      matcher.split(/[|,]/).map(&:strip)
    end

    def valid?(matcher)
      return true if all?(matcher)
      return false unless matcher.is_a?(String)
      return true if simple?(matcher)

      Regexp.new(matcher)
      true
    rescue RegexpError
      false
    end

    def matches?(matcher, value)
      return true if all?(matcher)
      return false unless matcher.is_a?(String)

      text = value.to_s
      return alternatives(matcher).include?(text) if simple?(matcher)

      Regexp.new(matcher).match?(text)
    rescue RegexpError
      false
    end

    def first_alternative(matcher)
      return nil if all?(matcher) || !simple?(matcher)

      alternatives(matcher).reject(&:empty?).first
    end

    def overlap?(left, right)
      return true if all?(left) || all?(right)

      left == right
    end
  end
end
