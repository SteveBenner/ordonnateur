#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "open3"
require "shellwords"
require "time"
require "timeout"

require_relative "../hook_script"
require_relative "../provenance/facade"
require_relative "../provenance/observer"

module Ordonnateur
  module Web
    class Hooks
      THROTTLE_SECONDS = 5.0
      OPEN_TIMEOUT = 10
      MIME_TIMEOUT = 3
      OPEN_GRACE = 2
      DEFAULT_LIMIT = 200
      MAX_LIMIT = 1000
      DETAIL_EVENTS = 200
      HANDLED = [
        Ordonnateur::Error, Rplugin::Error, SystemCallError, IOError, JSON::ParserError, ArgumentError, KeyError, TypeError,
        NoMethodError, Timeout::Error
      ].freeze
      TEXT_MIMES = %w[
        application/json application/javascript application/x-javascript application/x-shellscript application/x-sh
        application/x-ruby application/x-python application/x-python-code application/x-perl application/x-empty
        inode/x-empty
      ].freeze
      TEXT_EXTENSIONS = %w[.sh .bash .zsh .rb .py .pl .js .mjs .cjs .json .txt .md .yml .yaml .toml .conf .cfg .ini].freeze
      SAFE_ATTR = /[A-Za-z0-9!#$&+.^_`|~-]/.freeze
      NO_DISPLAY = "the machine that runs the server has no display"
      NO_OPENER = "no desktop opener (xdg-open or open) is on the PATH of the server"

      def initialize(ports:, settings:, layout:, plans:, logger: nil)
        @ports = ports
        @settings = settings
        @layout = layout
        @plans = plans
        @logger = logger
        @seen = {}
        @seen_lock = Mutex.new
      end

      def facade
        Provenance::Facade.for(ports: @ports, settings: @settings)
      end

      def desktop
        display = !env_text("DISPLAY").empty? || !env_text("WAYLAND_DISPLAY").empty? || RUBY_PLATFORM.include?("darwin")
        return { "open" => false, "reason" => NO_DISPLAY } unless display
        return { "open" => false, "reason" => NO_OPENER } unless opener

        { "open" => true, "reason" => nil }
      end

      def provenance_status
        guarded({ "enabled" => true, "store" => "local", "degraded" => true }) do
          store = facade
          status = store.status
          { "enabled" => store.enabled?, "store" => status[:store], "degraded" => status[:degraded] }
        end
      end

      def locate(id, project)
        payload, inventory = @layout.build_full(project, observe: false)
        hook = inventory.hooks.find { |item| item.id == id }
        row = payload["hooks"].find { |item| item["id"] == id }
        raise Failure.new(404, "not_found", "no such hook") unless hook && row

        [hook, row, inventory]
      end

      def detail(id, project)
        hook, row, inventory = locate(id, project)
        root = project ? inventory.root : nil
        script = HookScript.resolve(hook, project_root: root)
        store = facade
        events = safe_history(store, hook.id, DETAIL_EVENTS)
        status = safe_status(store)
        {
          "hook" => row, "script" => script_hash(script), "command_words" => HookScript.command_words(hook),
          "provenance" => status.slice("store", "degraded").merge("summary" => summary(events), "events" => events),
          "capabilities" => capabilities(hook, inventory.hooks, root, script),
          "ai" => ai(hook.id, project)
        }
      end

      def script_download(id, project)
        hook, _row, inventory = locate(id, project)
        script = HookScript.resolve(hook, project_root: project ? inventory.root : nil)
        raise Failure.new(404, "not_found", "no servable script: #{script.refusal}") if %w[missing unreadable].include?(script.kind)
        raise Failure.new(422, "refused", script.refusal.to_s) unless servable?(script)

        [read_script(script.path), disposition(File.basename(script.path))]
      rescue SystemCallError => e
        @logger&.error("hooks: script #{id} cannot be read: #{e.class}: #{e.message}")
        raise Failure.new(404, "not_found", "the script cannot be read")
      end

      def open_desktop(id, project, target)
        raise Failure.new(422, "invalid", "target must be file or folder") unless %w[file folder].include?(target)

        hook, _row, inventory = locate(id, project)
        view = desktop
        raise Failure.new(422, "no_desktop", view["reason"]) unless view["open"]

        script = HookScript.resolve(hook, project_root: project ? inventory.root : nil)
        raise Failure.new(422, "refused", script.refusal.to_s) if script.kind == "refused"
        raise Failure.new(422, "refused", "the hook names no script file") if script.path.nil?

        path = target == "folder" ? folder_target(script.path) : file_target(script)
        launch(path)
        { "opened" => true, "target" => target, "path" => path }
      end

      def provenance(query)
        limit = limit_param(query["limit"])
        hook = query["hook"].to_s.empty? ? nil : query["hook"]
        store = facade
        status = safe_status(store)
        { "store" => status["store"], "degraded" => status["degraded"], "note" => status["note"], "events" => safe_history(store, hook, limit) }
      end

      def on_layout(inventory, project)
        observe(inventory, project: project ? inventory.root : nil, via: "web", throttle: true)
      end

      def tick(pinned_roots)
        guarded do
          observe(@layout.inventory_for(nil), project: nil, via: "tick", throttle: false)
        end
        Array(pinned_roots).each do |root|
          guarded do
            next unless File.directory?(root)

            inventory = @layout.inventory_for(root)
            observe(inventory, project: inventory.root, via: "tick", throttle: false, user: false)
          end
        end
        nil
      end

      private

      def guarded(default = nil)
        yield
      rescue *HANDLED => e
        @logger&.error("hooks: #{e.class}: #{e.message}")
        default
      end

      def env_text(name)
        ENV.fetch(name, "")
      end

      def read_script(path)
        limit = HookScript::SERVE_LIMIT
        raise Failure.new(422, "refused", "#{path} is above #{limit} bytes") if File.size(path) > limit

        bytes = File.open(path, "rb") { |file| file.read(limit + 1) }.to_s
        raise Failure.new(422, "refused", "#{path} is above #{limit} bytes") if bytes.bytesize > limit

        bytes
      end

      def servable?(script)
        %w[text binary].include?(script.kind) || (script.kind == "too_large" && script.size.to_i <= HookScript::SERVE_LIMIT)
      end

      def folder_target(script_path)
        path = File.dirname(script_path)
        raise Failure.new(422, "refused", "#{path} is not a folder") unless File.directory?(path)
        raise Failure.new(422, "refused", "#{path} is under a credential directory") if HookScript.credential?(path, Dir.home)

        path
      end

      def file_target(script)
        unless script.kind == "text" && text_like?(script.path)
          raise Failure.new(422, "refused", "this file type is not opened as a file; open the folder instead")
        end

        script.path
      end

      def observe(inventory, project:, via:, throttle:, user: true)
        Provenance::Observer.each_scope(inventory.hooks, project: project, user: user) do |_scope, key, hooks|
          next if throttle && throttled?(key)

          guarded do
            Provenance::Observer.call(
              ports: @ports, settings: @settings, hooks: hooks, scope_key: key, via: via, at: Time.now.utc
            )
          end
        end
      end

      def throttled?(key)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @seen_lock.synchronize do
          last = @seen[key]
          next true if last && now - last < THROTTLE_SECONDS

          @seen[key] = now
          false
        end
      end

      def safe_history(store, hook_id, limit)
        guarded([]) { store.history(hook_id: hook_id, limit: limit) }
      end

      def safe_status(store)
        guarded({ "store" => "local", "degraded" => true, "note" => "the provenance store did not answer" }) do
          status = store.status
          { "store" => status[:store], "degraded" => status[:degraded], "note" => status[:note] }
        end
      end

      def summary(events)
        return { "count" => 0, "first_at" => nil, "first_kind" => nil, "last_at" => nil, "last_kind" => nil } if events.empty?

        first = events.min_by { |event| event["at"].to_s }
        last = events.first
        { "count" => events.length, "first_at" => first["at"], "first_kind" => first["kind"], "last_at" => last["at"], "last_kind" => last["kind"] }
      end

      def script_hash(script)
        script.to_h.transform_keys(&:to_s)
      end

      def capabilities(hook, hooks, root, script)
        view = desktop
        folder = !script.path.nil? && script.kind != "refused" && File.directory?(File.dirname(script.path)) &&
                 !HookScript.credential?(File.dirname(script.path), Dir.home)
        {
          "download" => servable?(script), "open_file" => (view["open"] && script.kind == "text" && text_like?(script.path)) || false,
          "open_folder" => (view["open"] && folder) || false, "edit_mode" => @plans.edit_enabled?,
          "edit_script" => stringify(HookScript.editability(hook, hooks: hooks, project_root: root)),
          "delete_hook" => stringify(HookScript.deletability(hook, hooks: hooks, project_root: root))
        }
      end

      def stringify(verdict)
        { "allowed" => verdict[:allowed], "refusal" => verdict[:refusal] }
      end

      def ai(id, project)
        word = Shellwords.escape(id)
        tail = project ? " --project #{Shellwords.escape(project)}" : ""
        cli = {
          "show" => "ordonnateur hook show #{word}#{tail} --content",
          "edit" => "ordonnateur hook edit #{word}#{tail} --from-file PATH",
          "delete" => "ordonnateur hook delete #{word}#{tail}"
        }
        prompt = "Use the ordonnateur skill. Run `#{cli['show']}` first and read the script. Then change it with " \
                 "`#{cli['edit']}` or remove the hook with `#{cli['delete']}`, show me the plan diff and the policy " \
                 "verdict, and apply only after I say yes. Never call the ordonnateur web API."
        { "cli" => cli, "skill" => "ordonnateur", "prompt" => prompt }
      end

      def text_like?(path)
        return false unless path && File.file?(path)

        mime = file_mime(path)
        return mime.start_with?("text/") || TEXT_MIMES.include?(mime) if mime

        TEXT_EXTENSIONS.include?(File.extname(path).downcase)
      end

      def file_mime(path)
        Open3.popen2("file", "--mime-type", "-b", "--", path, err: File::NULL) do |stdin, stdout, waiter|
          stdin.close
          begin
            out = Timeout.timeout(MIME_TIMEOUT) { stdout.read }
          rescue Timeout::Error
            kill_quietly("KILL", waiter.pid)
            waiter.join
            return nil
          end
          waiter.value.success? && !out.strip.empty? ? out.strip : nil
        end
      rescue SystemCallError
        nil
      end

      def kill_quietly(signal, target)
        Process.kill(signal, target)
      rescue Errno::ESRCH
        nil
      end

      def opener
        names = RUBY_PLATFORM.include?("darwin") ? %w[open] : %w[xdg-open]
        names.find do |name|
          env_text("PATH").split(File::PATH_SEPARATOR).any? { |dir| File.file?(File.join(dir, name)) && File.executable?(File.join(dir, name)) }
        end
      end

      def launch(path)
        pid = Process.spawn(opener, path, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
        waiter = Process.detach(pid)
        Thread.new do
          next if waiter.join(OPEN_TIMEOUT)

          kill_quietly("TERM", -pid)
          next if waiter.join(OPEN_GRACE)

          kill_quietly("KILL", -pid)
        end
      rescue SystemCallError => e
        @logger&.error("hooks: the desktop opener could not start: #{e.class}: #{e.message}")
        raise Failure.new(422, "no_desktop", "the desktop opener could not start")
      end

      def disposition(base)
        fallback = base.gsub(/[^A-Za-z0-9._-]/, "_")
        encoded = base.b.each_char.map { |char| SAFE_ATTR.match?(char) ? char : format("%%%02X", char.ord) }.join
        "attachment; filename=\"#{fallback}\"; filename*=UTF-8''#{encoded}"
      end

      def limit_param(value)
        return DEFAULT_LIMIT if value.to_s.empty?
        unless value.to_s.match?(/\A\d+\z/) && value.to_i.between?(1, MAX_LIMIT)
          raise Failure.new(422, "invalid", "limit must be a whole number from 1 to #{MAX_LIMIT}")
        end

        value.to_i
      end
    end
  end
end
