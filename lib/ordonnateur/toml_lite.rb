#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Ordonnateur
  module TomlLite
    class Unreadable < StandardError
    end

    ESCAPES = {
      "b" => "\b", "t" => "\t", "n" => "\n", "f" => "\f", "r" => "\r", '"' => '"', "\\" => "\\"
    }.freeze

    BARE_KEY = /[A-Za-z0-9_-]/.freeze
    DATETIME = /\A\d{4}-\d{2}-\d{2}([Tt ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?([Zz]|[+-]\d{2}:\d{2})?)?\z|\A\d{2}:\d{2}:\d{2}(\.\d+)?\z/.freeze

    module_function

    def parse(text)
      Reader.new(text.to_s.gsub("\r\n", "\n")).read
    end

    class Cursor
      attr_accessor :pos
      attr_reader :text

      def initialize(text)
        @text = text
        @pos = 0
      end

      def eof? = @pos >= @text.length

      def peek = @text[@pos]

      def starts?(token) = @text[@pos, token.length] == token

      def advance(count = 1)
        @pos += count
      end

      def line_at(position = @pos)
        @text[0...position].count("\n") + 1
      end

      def skip_inline_space
        advance while !eof? && [" ", "\t"].include?(peek)
      end

      def skip_comment
        advance until eof? || peek == "\n" if peek == "#"
      end

      def skip_blank
        loop do
          advance while !eof? && [" ", "\t", "\n"].include?(peek)
          break unless peek == "#"

          skip_comment
        end
      end

      def end_of_line!
        skip_inline_space
        skip_comment
        raise Unreadable, "unexpected text after value" unless eof? || peek == "\n"
      end

      def skip_to_next_line(from)
        index = @text.index("\n", from)
        @pos = index ? index + 1 : @text.length
      end
    end

    class Reader
      def initialize(text)
        @cursor = Cursor.new(text)
        @result = { hooks: {}, state: {}, plugins: {}, warnings: [] }
        @context = { kind: :ignore, in_scope: false }
      end

      def read
        loop do
          @cursor.skip_blank
          break if @cursor.eof?

          start = @cursor.pos
          begin
            statement
          rescue Unreadable => e
            report(start, e.message)
            @cursor.skip_to_next_line(start)
          end
        end
        @result
      end

      private

      def report(start, message)
        return unless @context[:in_scope]

        @result[:warnings] << { line: @cursor.line_at(start), message: message }
      end

      def statement
        if @cursor.starts?("[[")
          header(true)
        elsif @cursor.peek == "["
          header(false)
        else
          assignment
        end
      end

      def header(array)
        line = @cursor.line_at
        @cursor.advance(array ? 2 : 1)
        path = key_path
        closing = array ? "]]" : "]"
        @cursor.skip_inline_space
        raise Unreadable, "table header is not closed" unless @cursor.starts?(closing)

        @cursor.advance(closing.length)
        @cursor.end_of_line!
        enter(path, array, line)
      rescue Unreadable
        @context = { kind: :ignore, in_scope: true }
        raise
      end

      def enter(path, array, line)
        @context = { kind: :ignore, in_scope: %w[hooks plugins].include?(path.first) }
        return unless @context[:in_scope]

        if path.first == "hooks"
          enter_hooks(path, array, line)
        elsif path.length == 2
          @result[:plugins][path[1]] ||= {}
          @context = { kind: :plugin, target: @result[:plugins][path[1]], in_scope: true }
        end
      end

      def enter_hooks(path, array, line)
        if path.length == 3 && path[1] == "state"
          @result[:state][path[2]] ||= {}
          @context = { kind: :state, target: @result[:state][path[2]], in_scope: true }
        elsif path.length == 2 && array && path[1] != "state"
          group = { matcher: nil, hooks: [], handler_lines: [], line: line }
          (@result[:hooks][path[1]] ||= []) << group
          @context = { kind: :group, target: group, in_scope: true }
        elsif path.length == 3 && array && path[2] == "hooks"
          group = (@result[:hooks][path[1]] || []).last
          raise Unreadable, "hooks table without a #{path[1]} group" unless group

          handler = {}
          group[:hooks] << handler
          group[:handler_lines] << line
          @context = { kind: :handler, target: handler, in_scope: true }
        end
      end

      def assignment
        path = key_path
        @cursor.skip_inline_space
        raise Unreadable, "expected = after key" unless @cursor.peek == "="

        @cursor.advance
        @cursor.skip_inline_space
        value = read_value
        @cursor.end_of_line!
        assign(path, value)
      end

      def assign(path, value)
        target = @context[:target]
        return if target.nil?
        raise Unreadable, "dotted keys are not read" unless path.length == 1

        key = path.first
        case @context[:kind]
        when :group
          assign_group(target, key, value)
        when :handler, :state, :plugin
          target[key] = value
        end
      end

      def assign_group(group, key, value)
        if key == "matcher"
          group[:matcher] = value if value.is_a?(String)
        elsif key == "hooks" && value.is_a?(Array)
          value.each do |handler|
            next unless handler.is_a?(Hash)

            group[:hooks] << handler
            group[:handler_lines] << group[:line]
          end
        end
      end

      def key_path
        parts = []
        loop do
          @cursor.skip_inline_space
          parts << key_part
          @cursor.skip_inline_space
          break unless @cursor.peek == "."

          @cursor.advance
        end
        parts
      end

      def key_part
        c = @cursor.peek
        if c == '"'
          basic_string
        elsif c == "'"
          literal_string
        else
          start = @cursor.pos
          @cursor.advance while !@cursor.eof? && BARE_KEY.match?(@cursor.peek)
          raise Unreadable, "invalid key" if @cursor.pos == start

          @cursor.text[start...@cursor.pos]
        end
      end

      def read_value
        c = @cursor.peek
        return multiline_basic if @cursor.starts?('"""')
        return multiline_literal if @cursor.starts?("'''")
        return basic_string if c == '"'
        return literal_string if c == "'"
        return array if c == "["
        return inline_table if c == "{"

        bare
      end

      def bare
        start = @cursor.pos
        @cursor.advance while !@cursor.eof? && !["\n", ",", "]", "}", "#", " ", "\t"].include?(@cursor.peek)
        token = @cursor.text[start...@cursor.pos]
        raise Unreadable, "missing value" if token.empty?

        scalar(token)
      end

      def scalar(token)
        return true if token == "true"
        return false if token == "false"

        plain = token.delete("_")
        return Integer(plain, 10) if plain.match?(/\A[+-]?\d+\z/)
        return Integer(plain) if plain.match?(/\A0[xob][0-9a-fA-F_]+\z/)
        return Float(plain) if plain.match?(/\A[+-]?\d+(\.\d+)?([eE][+-]?\d+)?\z/)
        return plain.start_with?("-") ? -Float::INFINITY : Float::INFINITY if plain.match?(/\A[+-]?inf\z/)
        return Float::NAN if plain.match?(/\A[+-]?nan\z/)
        return token if DATETIME.match?(token)

        raise Unreadable, "unreadable value #{token[0, 30].inspect}"
      end

      def basic_string
        @cursor.advance
        out = +""
        loop do
          raise Unreadable, "string is not closed" if @cursor.eof? || @cursor.peek == "\n"

          c = @cursor.peek
          @cursor.advance
          return out if c == '"'

          out << (c == "\\" ? escape : c)
        end
      end

      def escape
        c = @cursor.peek
        raise Unreadable, "dangling escape" if c.nil?

        @cursor.advance
        return ESCAPES[c] if ESCAPES.key?(c)
        return unicode(4) if c == "u"
        return unicode(8) if c == "U"

        raise Unreadable, "unknown escape \\#{c}"
      end

      def unicode(width)
        digits = @cursor.text[@cursor.pos, width].to_s
        raise Unreadable, "bad unicode escape" unless digits.match?(/\A\h{#{width}}\z/)

        @cursor.advance(width)
        [digits.hex].pack("U")
      rescue RangeError
        raise Unreadable, "bad unicode escape"
      end

      def literal_string
        @cursor.advance
        start = @cursor.pos
        @cursor.advance until @cursor.eof? || @cursor.peek == "'" || @cursor.peek == "\n"
        raise Unreadable, "string is not closed" unless @cursor.peek == "'"

        value = @cursor.text[start...@cursor.pos]
        @cursor.advance
        value
      end

      def multiline_basic
        @cursor.advance(3)
        @cursor.advance if @cursor.peek == "\n"
        out = +""
        loop do
          raise Unreadable, "multi-line string is not closed" if @cursor.eof?

          if @cursor.starts?('"""')
            extra = 0
            extra += 1 while @cursor.text[@cursor.pos + 3 + extra] == '"' && extra < 2
            out << ('"' * extra)
            @cursor.advance(3 + extra)
            return out
          end
          c = @cursor.peek
          @cursor.advance
          if c == "\\"
            if @cursor.peek == "\n" || @cursor.peek == " " || @cursor.peek == "\t"
              @cursor.advance while !@cursor.eof? && [" ", "\t", "\n"].include?(@cursor.peek)
            else
              out << escape
            end
          else
            out << c
          end
        end
      end

      def multiline_literal
        @cursor.advance(3)
        @cursor.advance if @cursor.peek == "\n"
        close = @cursor.text.index("'''", @cursor.pos)
        raise Unreadable, "multi-line string is not closed" unless close

        value = @cursor.text[@cursor.pos...close]
        @cursor.pos = close + 3
        value
      end

      def array
        @cursor.advance
        items = []
        loop do
          @cursor.skip_blank
          raise Unreadable, "array is not closed" if @cursor.eof?

          if @cursor.peek == "]"
            @cursor.advance
            return items
          end
          items << read_value
          @cursor.skip_blank
          if @cursor.peek == ","
            @cursor.advance
          elsif @cursor.peek != "]"
            raise Unreadable, "expected , or ] in array"
          end
        end
      end

      def inline_table
        @cursor.advance
        table = {}
        loop do
          @cursor.skip_inline_space
          raise Unreadable, "inline table is not closed" if @cursor.eof? || @cursor.peek == "\n"

          if @cursor.peek == "}"
            @cursor.advance
            return table
          end
          path = key_path
          @cursor.skip_inline_space
          raise Unreadable, "expected = in inline table" unless @cursor.peek == "="

          @cursor.advance
          @cursor.skip_inline_space
          store_nested(table, path, read_value)
          @cursor.skip_inline_space
          if @cursor.peek == ","
            @cursor.advance
          elsif @cursor.peek != "}"
            raise Unreadable, "expected , or } in inline table"
          end
        end
      end

      def store_nested(table, path, value)
        node = table
        path[0...-1].each { |key| node = (node[key] ||= {}) }
        node[path.last] = value
      end
    end
  end
end
