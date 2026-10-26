#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "net/http"
require "uri"

module Rplugin
  module Adapters
    module Ordonnateur
      module RuiHub
        class FolderPicker < Rplugin::Ports::Base
          MODULE_ID = "composite.form.file-picker"
          ASSET = "/vendor/rui/#{MODULE_ID}/file-picker.js"
          DEFAULT_URL = "http://127.0.0.1:3095"
          KILL_SWITCH = "ORDONNATEUR_RUIHUB_DISABLED"
          URL_VARIABLE = "ORDONNATEUR_RUIHUB_URL"
          CONNECT_TIMEOUT_S = 2
          READ_TIMEOUT_S = 2
          CACHE_TTL_S = 30
          LOOPBACK = %w[127.0.0.1 localhost ::1 [::1]].freeze
          GATE = Mutex.new

          @cache = nil

          class << self
            attr_accessor :cache
          end

          def list(path:, hidden: false)
            raise Rplugin::Ports::NotHandled, "rui-hub draws the picker; ordonnateur lists folders"
          end

          def describe
            raise Rplugin::Ports::NotHandled, "#{KILL_SWITCH} is set" if ENV[KILL_SWITCH] == "1"

            GATE.synchronize do
              cached = self.class.cache
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              unless cached && now - cached[:at] < CACHE_TTL_S
                cached = { at: now, answer: probe }
                self.class.cache = cached
              end
              raise Rplugin::Ports::NotHandled, cached[:answer] unless cached[:answer].is_a?(Hash)

              cached[:answer]
            end
          end

          private

          def base
            URI.parse(ENV.fetch(URL_VARIABLE, DEFAULT_URL))
          end

          def probe
            uri = base
            return "rui-hub url is not a loopback http url" unless uri.is_a?(URI::HTTP) && LOOPBACK.include?(uri.host)

            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = CONNECT_TIMEOUT_S
            http.read_timeout = READ_TIMEOUT_S
            response = http.request(Net::HTTP::Head.new(ASSET))
            return "rui-hub does not serve #{MODULE_ID} yet (HTTP #{response.code})" unless response.code == "200"

            {
              "source" => "rui-hub",
              "component" => { "module" => MODULE_ID, "script" => "#{uri}#{ASSET}", "selectable" => "folder" }
            }
          rescue StandardError => e
            "rui-hub did not answer: #{e.class}"
          end
        end
      end
    end
  end
end
