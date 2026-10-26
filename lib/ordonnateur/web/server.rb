#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "fileutils"
require "json"
require "time"

require_relative "auth"
require_relative "limiter"
require_relative "layout"
require_relative "projects"
require_relative "plans"
require_relative "app"

module Ordonnateur
  module Web
    class Server
      LOG_LIMIT = 4 * 1024 * 1024
      ACCESS_FORMAT = "%t %m %U %s %{X-Request-Id}o".freeze

      class LogFile
        def initialize(path, limit = LOG_LIMIT)
          @path = path
          @limit = limit
          @lock = Mutex.new
          @io = open_log
        end

        def <<(text)
          @lock.synchronize do
            rotate if @io.size >= @limit
            @io << text
          end
          self
        end

        def close
          @lock.synchronize { @io.close unless @io.closed? }
        end

        private

        def open_log
          io = File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o600)
          io.sync = true
          io
        end

        def rotate
          @io.close
          File.rename(@path, "#{@path}.1")
          @io = open_log
        end
      end

      class Servlet < WEBrick::HTTPServlet::AbstractServlet
        def initialize(server, app)
          super(server)
          @app = app
        end

        def service(req, res)
          @app.call(req, res)
        end
      end

      Info = Struct.new(:bind, :port, :pid, :auth, :public_origin) do
        def host
          bind.to_s.include?(":") ? "[#{bind}]" : bind
        end

        def url(code = auth.mint)
          "#{Web.link_origin(bind.to_s, port, public_origin)}/#k=#{code}"
        end
      end

      def self.info_path
        File.join(Web.dir, "server.json")
      end

      def self.read_info
        data = JSON.parse(File.read(info_path))
        data.is_a?(Hash) ? data : nil
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def self.alive?(pid)
        return false unless pid.is_a?(Integer) && pid.positive?

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def self.running
        info = read_info
        info && alive?(info["pid"]) ? info : nil
      end

      def initialize(bind:, port:, read_only:, exposed:, public_origin:, ports:, settings:)
        @bind = bind
        @port = port
        @read_only = read_only
        @exposed = exposed
        @public_origin = public_origin
        @ports = ports
        @settings = settings
        @stopping = false
      end

      def run(&on_ready)
        Web.ensure_dir
        claim_info_file
        auth = Auth.new(secret: Auth.load_secret)
        @log = LogFile.new(File.join(Web.dir, "server.log"))
        logger = WEBrick::Log.new(@log, WEBrick::Log::INFO)
        context = build_context(auth, logger)
        serve(context, logger, auth, &on_ready)
      rescue Errno::EADDRINUSE
        raise Stop.new("port_in_use", "#{@bind}:#{@port} is already in use")
      rescue Errno::EACCES, Errno::EADDRNOTAVAIL => e
        raise Stop.new("bind_failed", "cannot bind #{@bind}:#{@port}: #{e.message}")
      ensure
        release_info_file
        @log&.close
      end

      private

      def build_context(auth, logger)
        layout = Layout.new(ports: @ports, settings: @settings)
        Context.new(
          bind: @bind, port: @port, read_only: @read_only, exposed: @exposed, auth: auth, logger: logger,
          public_origin: @public_origin, ports: @ports, settings: @settings, limiter: Limiter.new, layout: layout,
          projects: Projects.new(settings: @settings), plans: Plans.new(ports: @ports, settings: @settings, layout: layout)
        )
      end

      def serve(context, logger, auth, &on_ready)
        server = WEBrick::HTTPServer.new(
          BindAddress: @bind, Port: @port, Logger: logger, AccessLog: [[@log, ACCESS_FORMAT]],
          DoNotReverseLookup: true, ServerSoftware: "ordonnateur-web", RequestTimeout: 30
        )
        @server = server
        port = server.listeners.first.addr[1]
        context.port = port
        server.mount("/", Servlet, App.new(context))
        write_info(port)
        install_traps
        emit("start", port)
        on_ready&.call(Info.new(@bind, port, Process.pid, auth, @public_origin))
        server.start
        emit("stop", port)
      ensure
        server&.shutdown
      end

      def emit(kind, port)
        @ports.events.emit(
          "ordonnateur.web", { "event" => kind, "bind" => @bind, "port" => port, "read_only" => @read_only }
        )
      rescue StandardError
        nil
      end

      def install_traps
        %w[TERM INT].each do |name|
          Signal.trap(name) { stop }
        end
      end

      def stop
        return if @stopping

        @stopping = true
        Thread.new { @server&.shutdown }
      end

      def claim_info_file
        path = self.class.info_path
        return unless File.exist?(path)

        info = self.class.read_info
        if info && self.class.alive?(info["pid"])
          raise Stop.new("already_running", "ordonnateur web is already running as pid #{info['pid']} on #{info['bind']}:#{info['port']}")
        end

        File.rename(path, "#{path}.stale-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}")
      end

      def write_info(port)
        path = self.class.info_path
        temp = "#{path}.#{Process.pid}.tmp"
        record = {
          "pid" => Process.pid, "port" => port, "bind" => @bind, "public_origin" => @public_origin,
          "started_at" => Time.now.utc.iso8601
        }
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(record)) }
        File.rename(temp, path)
      end

      def release_info_file
        info = self.class.read_info
        File.delete(self.class.info_path) if info && info["pid"] == Process.pid
      rescue SystemCallError
        nil
      end
    end
  end
end
