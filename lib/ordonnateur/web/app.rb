#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "digest"
require "ipaddr"
require "json"
require "time"
require "uri"

require_relative "auth"

module Ordonnateur
  module Web
    class App
      CSP = "default-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
      SAFE = %w[GET HEAD].freeze
      MAX_BODY = 1024 * 1024
      PLAN_ID = /\Apl_[0-9a-f]{16}\z/.freeze
      HOST_FORMAT = /\A(\[[0-9a-fA-F:.]+\]|[A-Za-z0-9.-]+)(?::(\d+))?\z/.freeze
      MIME = {
        ".html" => "text/html; charset=utf-8",
        ".js" => "text/javascript; charset=utf-8",
        ".mjs" => "text/javascript; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".json" => "application/json",
        ".webmanifest" => "application/manifest+json",
        ".svg" => "image/svg+xml",
        ".png" => "image/png",
        ".ico" => "image/x-icon",
        ".txt" => "text/plain; charset=utf-8"
      }.freeze

      Exchange = Struct.new(:req, :res, :id, :session)

      def initialize(context)
        @ctx = context
      end

      def call(req, res)
        exchange = Exchange.new(req, res, Web.new_request_id, nil)
        res["X-Request-Id"] = exchange.id
        res["Content-Security-Policy"] = CSP
        res["X-Content-Type-Options"] = "nosniff"
        res["Referrer-Policy"] = "no-referrer"
        dispatch(exchange)
      rescue Failure => failure
        render_failure(exchange, failure)
      rescue Ordonnateur::Error => e
        render_failure(exchange, Failure.new(422, "refused", e.message))
      rescue StandardError => e
        @ctx.logger.error("#{exchange&.id} #{e.class}: #{e.message}")
        render_failure(exchange, Failure.new(500, "server", "internal error"))
      end

      private

      def fail!(status, kind, message, extra = {})
        raise Failure.new(status, kind, message, extra)
      end

      def render_failure(exchange, failure)
        res = exchange.res
        payload = { "error" => failure.kind, "message" => failure.message }
        failure.extra.each { |key, value| payload[key.to_s] = value }
        payload["request_id"] = exchange.id
        retry_after = payload.delete("retry_after")
        res.status = failure.status
        res["Content-Type"] = "application/json"
        res["Cache-Control"] = "no-store"
        res["Retry-After"] = retry_after.to_s if retry_after
        res.keep_alive = false if [411, 413].include?(failure.status)
        res.body = JSON.generate(payload)
      end

      def json(exchange, status, payload)
        res = exchange.res
        res.status = status
        res["Content-Type"] = "application/json"
        res.body = JSON.generate(payload)
      end

      def dispatch(exchange)
        req = exchange.req
        path = req.path
        guard_host(req)
        api = path == "/api" || path.start_with?("/api/")
        return serve_static(exchange) unless api

        exchange.res["Cache-Control"] = "no-store"
        guard_size(req)
        method = req.request_method
        rest = route_rest(path)
        if method == "POST" && rest == ["session"]
          origin = req["Origin"].to_s
          fail!(403, "forbidden", "the Origin is not this server") unless origin.empty? || allowed_origin?(origin)
          return route(exchange, rest)
        end
        exchange.session = @ctx.auth.lookup(cookie(req, Auth::COOKIE))
        fail!(401, "unauthorized", "no valid session; open a new link from the terminal") unless exchange.session
        guard_write(exchange, rest) unless SAFE.include?(method)
        route(exchange, rest)
      end

      def route_rest(path)
        parts = path.split("/").reject(&:empty?)
        parts[0, 2] == %w[api v1] ? parts[2..] : nil
      end

      def cookie(req, name)
        req["Cookie"].to_s.split(";").each do |pair|
          key, value = pair.strip.split("=", 2)
          return value.to_s if key == name
        end
        nil
      end

      def guard_write(exchange, rest)
        req = exchange.req
        fail!(405, "read_only", "ordonnateur web is running read-only") if @ctx.read_only && rest != ["session"]
        unless Auth.equal?(req[Auth::CSRF_HEADER], exchange.session.csrf)
          fail!(403, "forbidden", "the CSRF header is missing or wrong")
        end
        fail!(403, "forbidden", "the Origin is not this server") unless allowed_origin?(req["Origin"])
        granted, wait = @ctx.limiter.take(exchange.session)
        return if granted

        fail!(429, "rate_limited", "more than #{Limiter::LIMIT} changes in a minute", { retry_after: wait })
      end

      def guard_size(req)
        unless req["Transfer-Encoding"].to_s.empty?
          fail!(411, "length_required", "chunked request bodies are not accepted; send a Content-Length")
        end
        length = req["Content-Length"].to_i
        fail!(413, "too_large", "the request body is larger than #{MAX_BODY} bytes") if length > MAX_BODY
      end

      def guard_host(req)
        return if allowed_host?(req["Host"])

        fail!(403, "forbidden", "the Host header does not name this server")
      end

      def allowed_host?(header)
        match = HOST_FORMAT.match(header.to_s)
        return false unless match

        if @ctx.public_origin
          public_uri = URI.parse(@ctx.public_origin)
          return true if match[1].downcase == public_uri.host.downcase && (match[2] || "443").to_i == public_uri.port
        end
        return false unless (match[2] || "80").to_i == @ctx.port

        name = match[1].downcase
        return true if name == "localhost"
        return true if name == bracketed(@ctx.bind)
        return true if @ctx.exposed && wildcard?(@ctx.bind) && ip_literal?(name)

        false
      end

      def allowed_origin?(origin)
        return origin.to_s == @ctx.public_origin if @ctx.public_origin

        match = %r{\Ahttp://(.+)\z}.match(origin.to_s)
        !match.nil? && allowed_host?(match[1])
      end

      def bracketed(address)
        text = address.to_s.downcase
        text.include?(":") ? "[#{text}]" : text
      end

      def wildcard?(address)
        ["0.0.0.0", "::"].include?(address.to_s)
      end

      def ip_literal?(name)
        IPAddr.new(name.delete("[]"))
        true
      rescue IPAddr::Error
        false
      end

      def serve_static(exchange)
        req = exchange.req
        res = exchange.res
        fail!(405, "method_not_allowed", "only GET and HEAD are served here") unless SAFE.include?(req.request_method)
        file = static_file(req.path)
        fail!(404, "not_found", "no such file") unless file
        stat = File.stat(file)
        etag = %("#{Digest::SHA256.hexdigest("#{stat.size}-#{stat.mtime.to_f}")[0, 24]}")
        res["ETag"] = etag
        res["Cache-Control"] = "no-cache"
        res["Content-Type"] = MIME.fetch(File.extname(file).downcase)
        if none_match?(req, etag)
          res.status = 304
          res.body = ""
          return
        end
        res.status = 200
        res.body = File.binread(file)
      end

      def none_match?(req, etag)
        req["If-None-Match"].to_s.split(",").map { |item| item.strip.sub(%r{\AW/}, "") }.include?(etag)
      end

      def static_file(raw)
        path = raw.to_s
        return nil if path.include?("\0") || path.include?("\\")

        parts = path.split("/").reject(&:empty?)
        return nil if parts.any? { |part| part.start_with?(".") }

        parts = ["index.html"] if parts.empty?
        candidate = File.join(PUBLIC_DIR, *parts)
        candidate = File.join(candidate, "index.html") if File.directory?(candidate)
        return nil unless File.file?(candidate) && MIME.key?(File.extname(candidate).downcase)

        real = File.realpath(candidate)
        root = File.realpath(PUBLIC_DIR)
        real.start_with?("#{root}/") ? real : nil
      rescue ArgumentError, SystemCallError
        nil
      end

      def only(exchange, *methods)
        method = exchange.req.request_method
        method = "GET" if method == "HEAD"
        return if methods.include?(method)

        fail!(405, "method_not_allowed", "unsupported method")
      end

      def body_object(exchange)
        raw = exchange.req.body.to_s
        fail!(413, "too_large", "the request body is larger than #{MAX_BODY} bytes") if raw.bytesize > MAX_BODY
        return {} if raw.strip.empty?

        data = JSON.parse(raw)
        fail!(400, "bad_json", "the request body is not a JSON object") unless data.is_a?(Hash)

        data
      rescue JSON::ParserError
        fail!(400, "bad_json", "the request body is not valid JSON")
      end

      def project_query(exchange)
        pairs = URI.decode_www_form(exchange.req.query_string.to_s).to_h
        value = pairs["project"].to_s
        return nil if value.empty?

        unless value.start_with?("/") && !value.include?("\0") && File.directory?(value)
          fail!(422, "invalid", "project must be an absolute path to an existing directory")
        end
        value
      rescue ArgumentError
        fail!(400, "bad_request", "the query string is not valid")
      end

      def route(exchange, rest)
        fail!(404, "not_found", "no such route") if rest.nil? || rest.empty?
        case rest.first
        when "session" then route_session(exchange, rest)
        when "config" then route_config(exchange, rest)
        when "projects" then route_projects(exchange, rest)
        when "folders" then route_folders(exchange, rest)
        when "state" then route_state(exchange, rest)
        when "fingerprint" then route_fingerprint(exchange, rest)
        when "layout" then route_layout(exchange, rest)
        when "plans" then route_plans(exchange, rest)
        else fail!(404, "not_found", "no such route")
        end
      end

      def session_payload(session)
        { "csrf" => session.csrf, "expires_at" => @ctx.auth.expires_at(session) }
      end

      def cookie_attributes
        "HttpOnly; SameSite=Strict; Path=/#{'; Secure' if @ctx.public_origin}"
      end

      def route_session(exchange, rest)
        fail!(404, "not_found", "no such route") unless rest.length == 1
        res = exchange.res
        case exchange.req.request_method
        when "POST"
          code = body_object(exchange)["code"]
          session = @ctx.auth.exchange(code)
          fail!(401, "unauthorized", "the link is used or expired; open a new link from the terminal") unless session
          res["Set-Cookie"] = "#{Auth::COOKIE}=#{session.token}; #{cookie_attributes}"
          json(exchange, 200, session_payload(session))
        when "GET", "HEAD"
          json(exchange, 200, session_payload(exchange.session))
        when "DELETE"
          @ctx.auth.close(exchange.session.token)
          res["Set-Cookie"] = "#{Auth::COOKIE}=; #{cookie_attributes}; Max-Age=0"
          json(exchange, 200, { "ok" => true })
        else
          fail!(405, "method_not_allowed", "unsupported method")
        end
      end

      def policy_source
        names = @ctx.ports.chain(:policy)
        names.first.to_s.include?("Polispec") ? "polispec" : "standalone"
      rescue StandardError
        "standalone"
      end

      def folder_picker_description
        @ctx.ports.folder_picker.describe
      rescue StandardError
        { "source" => "standalone", "component" => nil }
      end

      def config_payload
        refused = Model::CLAUDE_EVENTS.reject { |event| Model::SEQUENCEABLE_EVENTS.include?(event) }
        {
          "version" => Web.version,
          "theme" => @ctx.settings.get("web.theme"),
          "read_only" => @ctx.read_only == true,
          "enabled" => @ctx.settings.on?("web.enabled"),
          "policy_source" => policy_source,
          "folder_picker" => folder_picker_description,
          "discover" => @ctx.settings.on?("web.discover"),
          "events" => { "claude-code" => LIFECYCLE["claude-code"], "codex" => LIFECYCLE["codex"], "hermes" => Model::HERMES_EVENTS, "antigravity" => Model::ANTIGRAVITY_EVENTS },
          "hermes" => { "tool_events" => Model::HERMES_TOOL_EVENTS, "blocking_events" => Model::HERMES_BLOCKING_EVENTS },
          "antigravity" => { "tool_events" => Model::ANTIGRAVITY_TOOL_EVENTS, "member_spec" => Model::ANTIGRAVITY_MEMBER_SPEC },
          "sequenceable" => LIFECYCLE["claude-code"].select { |event| Model::SEQUENCEABLE_EVENTS.include?(event) },
          "not_sequenceable" => LIFECYCLE["claude-code"].select { |event| refused.include?(event) }
                                                        .to_h { |event| [event, Model.refused_reason(event)] },
          "guard_events" => LIFECYCLE["claude-code"].select { |event| Model::GUARD_EVENTS.include?(event) },
          "effects_text" => EFFECTS_TEXT
        }
      end

      def route_config(exchange, rest)
        fail!(404, "not_found", "no such route") unless rest.length == 1
        only(exchange, "GET")
        json(exchange, 200, config_payload)
      end

      def route_projects(exchange, rest)
        fail!(404, "not_found", "no such route") unless rest.length == 1
        only(exchange, "GET")
        json(exchange, 200, @ctx.projects.list)
      end

      def route_folders(exchange, rest)
        fail!(404, "not_found", "no such route") unless rest.length == 1
        only(exchange, "GET")
        pairs = URI.decode_www_form(exchange.req.query_string.to_s).to_h
        path = pairs["path"].to_s
        path = Dir.home if path.empty?
        json(exchange, 200, @ctx.ports.folder_picker.list(path: path, hidden: pairs["hidden"] == "1"))
      rescue ArgumentError
        fail!(400, "bad_request", "the query string is not valid")
      end

      def route_state(exchange, rest)
        fail!(404, "not_found", "no such route") unless rest == %w[state projects]
        only(exchange, "PUT")
        pinned = body_object(exchange)["pinned"]
        json(exchange, 200, { "pinned" => @ctx.projects.save_pinned(pinned) })
      end

      def route_fingerprint(exchange, rest)
        fail!(404, "not_found", "no such route") unless rest.length == 1
        only(exchange, "GET")
        json(exchange, 200, @ctx.layout.fingerprint(project_query(exchange)))
      rescue HarnessFileError => e
        fail!(422, "harness_file_error", e.message)
      end

      def route_layout(exchange, rest)
        fail!(404, "not_found", "no such route") unless rest.length == 1
        only(exchange, "GET")
        layout = @ctx.layout.build(project_query(exchange))
        etag = %("#{Digest::SHA256.hexdigest(layout['fingerprint']['config'] + layout['fingerprint']['timings'])}")
        res = exchange.res
        res["ETag"] = etag
        if none_match?(exchange.req, etag)
          res.status = 304
          res.body = ""
          return
        end
        json(exchange, 200, layout)
      rescue HarnessFileError => e
        fail!(422, "harness_file_error", e.message)
      end

      def route_plans(exchange, rest)
        method = exchange.req.request_method
        if rest.length == 1
          only(exchange, "POST")
          return json(exchange, 201, @ctx.plans.create(body_object(exchange)))
        end
        fail!(404, "not_found", "no such plan") unless PLAN_ID.match?(rest[1].to_s)
        if rest.length == 2
          only(exchange, "GET")
          return json(exchange, 200, @ctx.plans.fetch(rest[1]))
        end
        fail!(404, "not_found", "no such route") unless rest.length == 3 && rest[2] == "apply"
        fail!(405, "method_not_allowed", "unsupported method") unless method == "POST"
        confirm = body_object(exchange)["confirm"]
        json(exchange, 200, @ctx.plans.apply(rest[1], confirm))
      end
    end
  end
end
