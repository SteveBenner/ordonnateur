#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Ordonnateur
  module FolderPicker
    class Standalone < Rplugin::Ports::Base
      MAX_ENTRIES = 1000

      def list(path:, hidden: false)
        target = path.to_s
        unless target.start_with?("/") && !target.include?("\0")
          raise Ordonnateur::Error, "path must be an absolute directory path"
        end

        real = File.realpath(target)
        raise Ordonnateur::Error, "#{target} is not a directory" unless File.directory?(real)

        folders = Dir.children(real).select do |name|
          (hidden || !name.start_with?(".")) && File.directory?(File.join(real, name))
        end
        folders.sort_by! { |name| [name.downcase, name] }
        {
          "path" => real,
          "parent" => real == "/" ? nil : File.dirname(real),
          "entries" => folders.first(MAX_ENTRIES).map { |name| { "name" => name, "path" => File.join(real, name) } },
          "total" => folders.length,
          "truncated" => folders.length > MAX_ENTRIES
        }
      rescue SystemCallError => e
        raise Ordonnateur::Error, "#{target} cannot be read: #{e.message.sub(/ @ .*/, '')}"
      end

      def describe
        { "source" => "standalone", "component" => nil }
      end
    end
  end
end
