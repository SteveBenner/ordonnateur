#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "digest"

module Ordonnateur
  module Canonical
    module_function

    def sort(value)
      case value
      when Hash
        value.sort_by { |key, _| key.to_s }.to_h { |key, item| [key.to_s, sort(item)] }
      when Array
        value.map { |item| sort(item) }
      else
        value
      end
    end

    def json(value)
      JSON.generate(sort(value))
    end

    def hex(matcher, hook)
      Digest::SHA256.hexdigest(json({ "matcher" => matcher, "hook" => hook }))
    end

    def digest(matcher, hook)
      "sha256:#{hex(matcher, hook)}"
    end

    def short(matcher, hook)
      hex(matcher, hook)[0, 8]
    end
  end
end
