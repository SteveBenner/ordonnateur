#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "yaml"
require "time"

require_relative "model"
require_relative "overlay"
require_relative "harnesses/claude_code"

module Ordonnateur
  module Card
    class Invalid < StandardError
    end

    KEYS = %w[schema harness scope settings_file unguarded events].freeze

    module_function

    def blank(scope, settings_file)
      {
        "schema" => Model::CARD_SCHEMA,
        "harness" => "claude-code",
        "scope" => scope,
        "settings_file" => settings_file,
        "unguarded" => [],
        "events" => {}
      }
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def read(path)
      overlaid, replaced = Overlay.read(path)
      raise Errno::ENOENT if overlaid && replaced.nil?

      text = overlaid ? replaced : File.read(path)
      data = YAML.safe_load(text, permitted_classes: [Time], aliases: false)
      validate!(data)
      data
    rescue Errno::ENOENT
      raise Invalid, "card #{path} does not exist"
    rescue SystemCallError, IOError => e
      raise Invalid, "card #{path} is unreadable: #{e.message}"
    rescue Psych::Exception => e
      raise Invalid, "card #{path} does not parse: #{e.message.lines.first.to_s.strip}"
    rescue Invalid => e
      raise Invalid, "card #{path} is invalid: #{e.message}"
    end

    def load_if_present(path)
      overlaid, replaced = Overlay.read(path)
      return replaced.nil? ? nil : read(path) if overlaid

      File.file?(path) ? read(path) : nil
    end

    def validate!(data)
      raise Invalid, "not a mapping" unless data.is_a?(Hash)
      raise Invalid, "schema must be #{Model::CARD_SCHEMA}" unless data["schema"] == Model::CARD_SCHEMA
      raise Invalid, "harness must be claude-code" unless data["harness"] == "claude-code"
      raise Invalid, "scope must be user or local" unless %w[user local].include?(data["scope"])
      raise Invalid, "settings_file must be a string" unless data["settings_file"].is_a?(String)
      data["unguarded"] = [] if data["unguarded"].nil?
      unless data["unguarded"].is_a?(Array) && data["unguarded"].all?(String)
        raise Invalid, "unguarded must be a list of digests"
      end
      data["events"] = {} if data["events"].nil?
      raise Invalid, "events must be a mapping" unless data["events"].is_a?(Hash)

      data["events"].each { |event, entry| validate_event!(event, entry) }
    end

    def validate_event!(event, entry)
      raise Invalid, "event #{event} must be a mapping" unless entry.is_a?(Hash)

      entry["stop_on_block"] = false if entry["stop_on_block"].nil?
      raise Invalid, "event #{event} stop_on_block must be true or false" unless [true, false].include?(entry["stop_on_block"])
      raise Invalid, "event #{event} members must be a list" unless entry["members"].is_a?(Array)

      entry["members"].each_with_index do |member, index|
        label = "event #{event} member #{index + 1}"
        raise Invalid, "#{label} must be a mapping" unless member.is_a?(Hash)
        raise Invalid, "#{label} needs an id" unless member["id"].is_a?(String) && !member["id"].empty?
        raise Invalid, "#{label} needs a hook mapping" unless member["hook"].is_a?(Hash)
        raise Invalid, "#{label} matcher must be a string or null" unless member["matcher"].nil? || member["matcher"].is_a?(String)
        raise Invalid, "#{label} needs a digest" unless member["digest"].is_a?(String)
      end
    end

    def digest_ok?(member)
      member["digest"] == Canonical.digest(member["matcher"], member["hook"])
    end

    def member_for(hook, at: Time.now.utc)
      {
        "id" => hook.id,
        "matcher" => hook.matcher,
        "hook" => deep_copy(hook.hook),
        "digest" => hook.digest,
        "absorbed_at" => at.utc.iso8601
      }
    end

    def dump(card)
      ordered = {}
      KEYS.each { |key| ordered[key] = card[key] }
      card.each { |key, value| ordered[key] = value unless ordered.key?(key) }
      YAML.dump(ordered)
    end

    def members(card, event)
      entry = card && card["events"][event]
      entry ? entry["members"] : []
    end

    def timeout_total(event, members)
      members.sum do |member|
        value = member["hook"]["timeout"]
        value.is_a?(Numeric) ? value : Model.default_timeout(event)
      end + 10
    end

    def member_hooks(card, scope, path)
      return [] unless card

      card["events"].flat_map do |event, entry|
        entry["members"].each_with_index.map do |member, index|
          hook = Model::Hook.new(
            harness: "claude-code", scope: scope, source_file: path, event: event, matcher: member["matcher"],
            hook: member["hook"], line: nil, group_index: nil, handler_index: index
          )
          hook.id = member["id"]
          hook.digest = member["digest"]
          hook.status = "member##{index + 1}"
          hook.member_position = index + 1
          hook.absorbable = false
          hook.reason = "is already a member of the #{scope} card"
          hook
        end
      end
    end

    def unguarded_map(root)
      %w[user local].to_h do |scope|
        path = Harnesses::ClaudeCode.card_path(scope, root)
        card = begin
          load_if_present(path)
        rescue Invalid
          nil
        end
        [scope, card ? card["unguarded"] : []]
      end
    end

    def cards(root)
      %w[user local].to_h do |scope|
        path = Harnesses::ClaudeCode.card_path(scope, root)
        entry = begin
          { path: path, card: load_if_present(path), error: nil }
        rescue Invalid => e
          { path: path, card: nil, error: e.message }
        end
        [scope, entry]
      end
    end
  end
end
