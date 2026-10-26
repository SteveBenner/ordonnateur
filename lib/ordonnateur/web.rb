#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "digest"
require "fileutils"
require "ipaddr"
require "json"
require "optparse"
require "securerandom"
require "time"
require "uri"

require_relative "model"

module Ordonnateur
  module Web
    ROOT = File.expand_path("../..", __dir__)
    PUBLIC_DIR = File.join(ROOT, "web", "public")

    $LOAD_PATH.unshift(File.join(ROOT, "vendor", "webrick", "lib"))
    require "webrick"

    LIFECYCLE = {
      "claude-code" => %w[
        Setup SessionStart InstructionsLoaded UserPromptSubmit UserPromptExpansion PreToolUse PermissionRequest
        PermissionDenied PostToolUse PostToolUseFailure PostToolBatch SubagentStart SubagentStop TaskCreated
        TaskCompleted TeammateIdle Notification MessageDisplay Elicitation ElicitationResult PreCompact PostCompact
        PreModelSwitch PostModelSwitch ConfigChange CwdChanged DirectoryAdded FileChanged WorktreeCreate
        WorktreeRemove Stop StopFailure SessionEnd
      ].freeze,
      "codex" => %w[
        SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse SubagentStart SubagentStop
        PreCompact PostCompact Interrupt Stop SessionEnd
      ].freeze
    }.freeze

    EFFECTS_TEXT = "Running Claude Code sessions pick up the change through their settings file watcher; new sessions read it at start."
    EXPOSE_PHRASE = "expose ordonnateur web"
    USAGE_LINES = [
      "ordonnateur web [--bind ADDR] [--port N] [--public-origin URL] [--expose] [--open] [--read-only] [--json]",
      "ordonnateur web url [--json]"
    ].freeze

    class Stop < Ordonnateur::Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super("#{code}: #{message}")
      end
    end

    class Failure < StandardError
      attr_reader :status, :kind, :extra

      def initialize(status, kind, message, extra = {})
        super(message)
        @status = status
        @kind = kind
        @extra = extra
      end
    end

    Context = Struct.new(
      :bind, :port, :read_only, :exposed, :auth, :logger, :public_origin, :ports, :settings, :limiter, :layout,
      :projects, :plans, keyword_init: true
    )

    module_function

    def dir
      File.join(Rplugin::Paths.state_home, "ordonnateur", "web")
    end

    def ensure_dir
      FileUtils.mkdir_p(dir)
      File.chmod(0o700, dir)
    end

    def empty_root
      path = File.join(dir, "empty-root")
      FileUtils.mkdir_p(path)
      path
    end

    def new_request_id
      SecureRandom.hex(8)
    end

    def version
      File.read(File.join(ROOT, "VERSION")).strip
    end

    def loopback?(address)
      text = address.to_s.downcase
      return true if text == "localhost"

      IPAddr.new(text.delete("[]")).loopback?
    rescue IPAddr::Error
      false
    end

    def normalize_origin(raw)
      text = raw.to_s.strip
      return nil if text.empty?

      uri = URI.parse(text)
      valid = uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty? && uri.userinfo.nil? && uri.path.to_s.empty? &&
              uri.query.nil? && uri.fragment.nil?
      raise Ordonnateur::Usage, "web.public_origin must be one https origin: scheme, host and an optional port" unless valid

      port = uri.port == 443 ? "" : ":#{uri.port}"
      "https://#{uri.host.downcase}#{port}"
    rescue URI::InvalidURIError
      raise Ordonnateur::Usage, "web.public_origin must be one https origin: scheme, host and an optional port"
    end

    def link_origin(bind, port, public_origin)
      return public_origin if public_origin

      host = %w[0.0.0.0 ::].include?(bind) ? "127.0.0.1" : bind
      host = "[#{host}]" if host.include?(":")
      "http://#{host}:#{port}"
    end

    def parse_flags(argv)
      options = {}
      parser = OptionParser.new
      parser.banner = USAGE_LINES.first
      parser.on("--bind ADDR") { |value| options[:bind] = value }
      parser.on("--port N", Integer) { |value| options[:port] = value }
      parser.on("--public-origin URL") { |value| options[:public_origin] = value }
      parser.on("--expose") { options[:expose] = true }
      parser.on("--open") { options[:open] = true }
      parser.on("--read-only") { options[:read_only] = true }
      parser.on("--json") { options[:json] = true }
      parser.parse!(argv)
      raise Ordonnateur::Usage, "usage: #{USAGE_LINES.first}" unless argv.empty?

      options
    rescue OptionParser::ParseError => e
      raise Ordonnateur::Usage, "#{e.message}; usage: #{USAGE_LINES.first}"
    end

    def run(argv, out:, err:, ports:, settings:)
      argv = argv.dup
      return run_url(argv.drop(1), out) if argv.first == "url"

      options = parse_flags(argv)
      raise Stop.new("disabled", "ordonnateur web is disabled (web.enabled or ORDONNATEUR_WEB_DISABLED)") unless settings.on?("web.enabled")

      bind = options[:bind] || settings.get("web.bind")
      port = options[:port] || settings.get("web.port")
      raise Ordonnateur::Usage, "--port must be between 0 and 65535" unless port.is_a?(Integer) && port.between?(0, 65_535)

      public_origin = normalize_origin(options.key?(:public_origin) ? options[:public_origin] : settings.get("web.public_origin"))
      exposed = confirm_expose(bind, options, err)
      require_relative "web/server"
      server = Server.new(
        bind: bind, port: port, read_only: options[:read_only] == true, exposed: exposed, public_origin: public_origin,
        ports: ports, settings: settings
      )
      server.run { |info| announce(info, options, out, err) }
      0
    end

    def confirm_expose(bind, options, err)
      return false if loopback?(bind)
      raise Stop.new("expose_required", "#{bind} is not a loopback address; add --expose to serve on it") unless options[:expose]
      raise Stop.new("not_tty", "--expose needs a terminal to type the confirmation phrase") unless $stdin.tty?

      err.print "type `#{EXPOSE_PHRASE}` to serve on #{bind}: "
      err.flush
      answer = $stdin.gets.to_s.strip
      raise Stop.new("expose_required", "the confirmation phrase did not match") unless answer == EXPOSE_PHRASE

      true
    end

    def announce(info, options, out, err)
      url = info.url
      if options[:json]
        out.puts JSON.generate(
          { "url" => url, "bind" => info.bind, "port" => info.port, "pid" => info.pid, "read_only" => options[:read_only] == true }
        )
      else
        out.puts "ordonnateur web: serving #{info.host}:#{info.port}; stop with Ctrl-C"
        out.puts "open this link within 120 seconds, it works once:"
        out.puts url
      end
      out.flush
      open_link(url, err) if options[:open]
    end

    def open_link(url, err)
      opener = %w[xdg-open open].find do |name|
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
      end
      if opener
        pid = Process.spawn(opener, url, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
        Process.detach(pid)
      else
        err.puts "note: no xdg-open or open on PATH; open the link by hand"
      end
    rescue SystemCallError
      err.puts "note: could not start the browser opener; open the link by hand"
    end

    def run_url(argv, out)
      options = {}
      parser = OptionParser.new
      parser.banner = USAGE_LINES.last
      parser.on("--json") { options[:json] = true }
      parser.parse!(argv)
      raise Ordonnateur::Usage, "usage: #{USAGE_LINES.last}" unless argv.empty?

      require_relative "web/server"
      info = Server.running
      secret = Auth.read_secret
      raise Stop.new("not_running", "no running ordonnateur web server for this state home") unless info && secret

      origin = link_origin(info["bind"].to_s, info["port"], info["public_origin"])
      url = "#{origin}/#k=#{Auth.mint(secret)}"
      if options[:json]
        out.puts JSON.generate({ "url" => url, "bind" => info["bind"], "port" => info["port"], "pid" => info["pid"] })
      else
        out.puts url
      end
      0
    rescue OptionParser::ParseError => e
      raise Ordonnateur::Usage, "#{e.message}; usage: #{USAGE_LINES.last}"
    end
  end
end
