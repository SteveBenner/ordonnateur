#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Ordonnateur
  module Policy
    class Standalone < Rplugin::Ports::Base
      def judge(tool_name:, tool_input:, cwd:)
        { verdict: "allow", rule_id: nil, reason: "no policy engine on this host", source: "standalone" }
      end

      def protected?(command:, args: nil, plugin: nil)
        { protected: false, reason: nil }
      end
    end
  end
end
