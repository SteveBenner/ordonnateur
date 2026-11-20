#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "digest"
require "json"
require "socket"
require "time"
require "timeout"
require "uri"

module Rplugin
  module Adapters
    module Ordonnateur
      module Rdb
        class Unavailable < Rplugin::Error
        end

        class Provenance < Rplugin::Ports::Base
          CONNECT_TIMEOUT_S = 1.0
          READ_TIMEOUT_S = 1.5
          CALL_CAP_S = 3.0
          MAX_REPLY_BYTES = 8 * 1024 * 1024
          DEFAULT_URL = "redis://127.0.0.1:6379"
          DEFAULT_PREFIX = "ordonnateur"
          PREFIX_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/.freeze
          STREAM_DB = 4
          PERSIST_DB = 1
          STREAM_NAME = "stream"
          STREAM_CHANNEL = "provenance:events"
          SNAPSHOT_NAMESPACE = "provenance-snapshot"
          STREAM_MAXLEN = 100_000
          PAGE_SIZE = 500
          SCAN_CAP = 5000
          DEFAULT_LIMIT = 200
          SNAPSHOT_VERSION = "1"
          KILL_SWITCH = "ORDONNATEUR_RDB_DISABLED"

          class Session
            def initialize(url, db, credentials, deadline)
              @deadline = deadline
              @buffer = +"".b
              uri = parse(url)
              user = uri.user ? URI.decode_www_form_component(uri.user) : credentials[0]
              password = uri.password ? URI.decode_www_form_component(uri.password) : credentials[1]
              @socket = Socket.tcp(uri.host || "127.0.0.1", uri.port || 6379, connect_timeout: [CONNECT_TIMEOUT_S, remaining].min)
              authenticate(user, password)
              expect_ok(command("SELECT", db.to_s))
            rescue Unavailable
              close
              raise
            rescue SystemCallError, IOError, SocketError, Timeout::Error => e
              close
              raise Unavailable, "rdb connection failed: #{e.class.name}"
            end

            def command(*parts)
              send_all([parts])
              read_reply
            end

            def pipeline(commands)
              send_all(commands)
              commands.map { read_reply }
            end

            def close
              @socket&.close
            rescue IOError, SystemCallError
              nil
            end

            private

            def parse(url)
              uri = URI.parse(url.to_s)
              raise Unavailable, "rdb url scheme is not supported" unless uri.scheme == "redis"

              uri
            rescue URI::InvalidURIError
              raise Unavailable, "rdb url is not valid"
            end

            def authenticate(user, password)
              return if password.to_s.empty?

              expect_ok(user.to_s.empty? ? command("AUTH", password) : command("AUTH", user, password))
            end

            def expect_ok(reply)
              raise Unavailable, "rdb answered #{reply.inspect[0, 40]}" unless reply == "OK"
            end

            def remaining
              left = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              raise Unavailable, "rdb call exceeded #{CALL_CAP_S} seconds" unless left.positive?

              left
            end

            def send_all(commands)
              data = commands.map do |parts|
                "*#{parts.length}\r\n" + parts.map { |part| "$#{part.to_s.bytesize}\r\n#{part}\r\n" }.join
              end.join.b
              until data.empty?
                written = @socket.write_nonblock(data, exception: false)
                if written == :wait_writable
                  raise Unavailable, "rdb write timed out" unless @socket.wait_writable(remaining)
                else
                  data = data.byteslice(written..)
                end
              end
            end

            def fill
              chunk = @socket.read_nonblock(65_536, exception: false)
              if chunk == :wait_readable
                raise Unavailable, "rdb read timed out" unless @socket.wait_readable([READ_TIMEOUT_S, remaining].min)
              elsif chunk.nil?
                raise Unavailable, "rdb closed the connection"
              else
                @buffer << chunk
              end
            end

            def read_line
              loop do
                index = @buffer.index("\r\n")
                return @buffer.slice!(0, index + 2)[0, index] if index

                fill
              end
            end

            def read_bytes(count)
              raise Unavailable, "rdb sent a reply above #{MAX_REPLY_BYTES} bytes" if count > MAX_REPLY_BYTES

              fill while @buffer.bytesize < count + 2
              @buffer.slice!(0, count + 2)[0, count]
            end

            def read_reply
              line = read_line
              kind = line[0]
              body = line[1..]
              case kind
              when "+" then body
              when "-" then raise Unavailable, "rdb refused a command: #{body.to_s.split.first.to_s[0, 24]}"
              when ":" then body.to_i
              when "$"
                length = body.to_i
                length.negative? ? nil : read_bytes(length).force_encoding(Encoding::UTF_8)
              when "*"
                count = body.to_i
                count.negative? ? nil : Array.new(count) { read_reply }
              else raise Unavailable, "rdb sent an unreadable reply"
              end
            end
          end

          def record(events:)
            list = Array(events).map { |item| JSON.parse(JSON.generate(item)) }
            return 0 if list.empty?

            commands = [["MULTI"]]
            list.each do |item|
              commands << ["XADD", stream_key, "MAXLEN", "~", STREAM_MAXLEN.to_s, "*", "data", JSON.generate(item),
                           "hook_id", item["hook_id"].to_s, "kind", item["kind"].to_s, "at", item["at"].to_s]
            end
            commands << ["EXEC"]
            replies = with_session(write_url, STREAM_DB) { |session| session.pipeline(commands) }
            unless replies.last.is_a?(Array) && replies.last.length == list.length
              raise Unavailable, "rdb did not commit the events"
            end

            list.length
          rescue JSON::JSONError, TypeError
            raise Unavailable, "events could not be encoded"
          end

          def history(hook_id: nil, since: nil, limit: DEFAULT_LIMIT)
            cap = [limit.to_i, 1].max
            floor = since.nil? ? nil : to_millis(since)
            lower = floor ? "#{floor}-0" : "-"
            found = []
            scanned = 0
            start = "+"
            with_session(read_url, STREAM_DB) do |session|
              while found.length < cap && scanned < SCAN_CAP
                page = session.command("XREVRANGE", stream_key, start, lower, "COUNT", PAGE_SIZE.to_s) || []
                page.each do |entry_id, fields|
                  scanned += 1
                  item = decode(fields)
                  next if item.nil? || (hook_id && item["hook_id"] != hook_id.to_s)

                  found << item
                end
                break if page.length < PAGE_SIZE

                start = "(#{page.last[0]}"
              end
            end
            found.first(cap)
          end

          def snapshot(scope_key:)
            fields = with_session(read_url, PERSIST_DB) { |session| session.command("HGETALL", snapshot_key(scope_key)) }
            hash = Array(fields).each_slice(2).to_h
            rows = hash["rows"] ? JSON.parse(hash["rows"]) : {}
            rows.is_a?(Hash) ? rows : {}
          rescue JSON::ParserError => e
            warn("ordonnateur: rdb snapshot #{Digest::SHA256.hexdigest(scope_key.to_s)[0, 16]} is not valid JSON (#{e.class.name}); treated as empty")
            {}
          end

          def store_snapshot(scope_key:, rows:)
            body = JSON.generate(rows || {})
            with_session(write_url, PERSIST_DB) do |session|
              session.command(
                "HSET", snapshot_key(scope_key), "scope_key", scope_key.to_s, "rows", body,
                "_version", SNAPSHOT_VERSION, "_updated_at", Time.now.utc.iso8601
              )
            end
            true
          rescue JSON::GeneratorError
            raise Unavailable, "snapshot could not be encoded"
          end

          def status
            { store: "extension", degraded: false, note: nil }
          end

          def extension?
            true
          end

          private

          def with_session(url, db)
            raise Unavailable, "#{KILL_SWITCH} is set" if env_text(KILL_SWITCH) == "1"

            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + CALL_CAP_S
            session = Session.new(url, db, credentials, deadline)
            begin
              yield session
            rescue SystemCallError, IOError, SocketError, Timeout::Error => e
              raise Unavailable, "rdb call failed: #{e.class.name}"
            ensure
              session.close
            end
          end

          def env_text(name)
            ENV.fetch(name, "").to_s
          end

          def write_url
            value = env_text("RDB_WRITE_URL")
            value.empty? ? DEFAULT_URL : value
          end

          def read_url
            value = env_text("RDB_READ_URL")
            value.empty? ? write_url : value
          end

          def credentials
            user = env_text("RDB_USERNAME")
            password = env_text("RDB_PASSWORD")
            user.empty? || password.empty? ? [nil, nil] : [user, password]
          end

          def prefix
            value = env_text("ORDONNATEUR_RDB_PREFIX")
            value = DEFAULT_PREFIX if value.empty?
            raise Unavailable, "ORDONNATEUR_RDB_PREFIX is not a valid prefix" unless PREFIX_PATTERN.match?(value)

            value
          end

          def stream_key
            [prefix, STREAM_NAME, STREAM_CHANNEL].join(":")
          end

          def snapshot_key(scope_key)
            [prefix, SNAPSHOT_NAMESPACE, Digest::SHA256.hexdigest(scope_key.to_s)[0, 16]].join(":")
          end

          def decode(fields)
            hash = Array(fields).each_slice(2).to_h
            data = JSON.parse(hash["data"].to_s)
            data.is_a?(Hash) ? data : nil
          rescue JSON::ParserError
            nil
          end

          def to_millis(value)
            time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
            (time.to_f * 1000).floor
          rescue ArgumentError
            raise Unavailable, "since is not a time"
          end
        end
      end
    end
  end
end
