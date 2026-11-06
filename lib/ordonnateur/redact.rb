#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

module Ordonnateur
  module Redact
    MASK = "[redacted]"
    SENSITIVE_NAME = /token|secret|password|passphrase|credential|cookie|auth|key/i.freeze
    NAME_ONLY_KEYS = %w[env headers].freeze
    PROVIDER_KEYS = [
      /\bsk-[A-Za-z0-9_-]{16,}/, /\bghp_[A-Za-z0-9]{20,}/, /\bgithub_pat_[A-Za-z0-9_]{20,}/,
      /\bgho_[A-Za-z0-9]{20,}/, /\bglpat-[A-Za-z0-9_-]{16,}/, /\bxox[abprs]-[A-Za-z0-9-]{10,}/,
      /\bAKIA[0-9A-Z]{16}\b/, /\bAIza[0-9A-Za-z_-]{30,}/, /\bhf_[A-Za-z0-9]{24,}/
    ].freeze
    BEARER = /\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]{8,}/i.freeze
    FLAG = /(--[A-Za-z0-9-]*(?:token|secret|password|passphrase|credential|cookie|auth|key)[A-Za-z0-9-]*)(=|\s+)("[^"]*"|'[^']*'|[^\s"';|&]+)/i.freeze
    ASSIGNMENT = /(?<![\w.\/=-])([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'[^']*'|[^\s"';|&]*)/.freeze
    KEYED_VALUE = /(\b[\w.-]*(?:token|secret|password|passphrase|credential|cookie|auth|key)[\w.-]*"?\s*:\s*)("[^"]*"|'[^']*'|[^\s,}\]"']+)/i.freeze
    URL_QUERY = %r{(https?://[^\s"'?#]*)\?[^\s"'#]*}.freeze
    URL_USERINFO = %r{(https?://)[^\s/@"']+@}.freeze
    HEX_RUN = /\b[A-Fa-f0-9]{32,}\b/.freeze
    BASE64_RUN = /(?<![A-Za-z0-9+\/=_-])[A-Za-z0-9+_-]{32,}={0,2}(?![A-Za-z0-9+\/=_-])/.freeze
    BASE64_PATH_RUN = /(?<![A-Za-z0-9+\/=_-])[A-Za-z0-9+\/]{32,}={0,2}(?![A-Za-z0-9+\/=_-])/.freeze

    module_function

    def sensitive_name?(name)
      SENSITIVE_NAME.match?(name.to_s)
    end

    def tree(value, home: Dir.home, name: nil)
      if name && sensitive_name?(name) && !NAME_ONLY_KEYS.include?(name.to_s.downcase)
        return MASK
      end

      case value
      when Hash then hash(value, home)
      when Array then value.map { |item| tree(item, home: home) }
      when String then text(value, home: home)
      else value
      end
    end

    def hash(value, home)
      value.each_with_object({}) do |(key, item), memo|
        label = key.to_s
        memo[label] =
          if NAME_ONLY_KEYS.include?(label.downcase) && item.is_a?(Hash)
            item.keys.map(&:to_s)
          else
            tree(item, home: home, name: label)
          end
      end
    end

    def text(value, home: Dir.home)
      result = value.to_s.dup
      result = result.gsub(home, "~") unless home.to_s.empty? || home == "/"
      result = result.gsub(URL_USERINFO) { "#{Regexp.last_match(1)}#{MASK}@" }
      result = result.gsub(URL_QUERY) { "#{Regexp.last_match(1)}?#{MASK}" }
      result = result.gsub(BEARER) { "#{Regexp.last_match(1)} #{MASK}" }
      result = result.gsub(FLAG) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{MASK}" }
      result = result.gsub(KEYED_VALUE) { keyed(Regexp.last_match) }
      result = result.gsub(ASSIGNMENT) { assignment(Regexp.last_match) }
      PROVIDER_KEYS.each { |pattern| result = result.gsub(pattern, MASK) }
      result = result.gsub(HEX_RUN, MASK)
      result = result.gsub(BASE64_RUN) { |run| mixed?(run) ? MASK : run }
      result.gsub(BASE64_PATH_RUN) { |run| mixed?(run) && run.match?(/[A-Z]/) && run.match?(/[a-z]/) ? MASK : run }
    end

    def assignment(match)
      return match[0] if match[2] == MASK || match[2].empty?

      "#{match[1]}=#{MASK}"
    end

    def keyed(match)
      return match[0] if match[2].include?(MASK)

      quote = match[2][0] == '"' ? '"' : ""
      "#{match[1]}#{quote}#{MASK}#{quote}"
    end

    def mixed?(run)
      run.match?(/\d/) && run.match?(/[A-Za-z]/)
    end
  end
end
