#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "ordonnateur/cli"

module Plugin
  ID = "ordonnateur"

  module_function

  def run(args)
    Ordonnateur::Cli.run(args.dup)
  end
end
