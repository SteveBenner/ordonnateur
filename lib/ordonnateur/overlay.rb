#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Ordonnateur
  module Overlay
    KEY = :ordonnateur_overlay

    module_function

    def with(files)
      previous = Thread.current[KEY]
      Thread.current[KEY] = files.to_h { |path, text| [File.expand_path(path), text] }
      yield
    ensure
      Thread.current[KEY] = previous
    end

    def read(path)
      map = Thread.current[KEY]
      return [false, nil] unless map

      key = File.expand_path(path)
      map.key?(key) ? [true, map[key]] : [false, nil]
    end
  end
end
