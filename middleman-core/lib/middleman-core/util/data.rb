require 'yaml'
require 'json'
require 'pathname'
require 'hashie'
require 'memoist'

require 'middleman-core/util/binary'
require 'middleman-core/contracts'

module Middleman
  module Util
    include Contracts

    module_function

    class EnhancedHash < ::Hashie::Mash
      # include ::Hashie::Extensions::MergeInitializer
      # include ::Hashie::Extensions::MethodReader
      # include ::Hashie::Extensions::IndifferentAccess
    end

    # Recursively convert a normal Hash into a EnhancedHash
    #
    # @private
    # @param [Hash] data Normal hash
    # @return [Hash]
    Contract Hash => IsA['::Middleman::Util::EnhancedHash']
    def recursively_enhance(obj)
      if obj.is_a? ::Array
        obj.map { |e| recursively_enhance(e) }
      elsif obj.is_a? ::Hash
        EnhancedHash.new(obj)
      else
        obj
      end
    end

    module Data
      extend Memoist
      include Contracts

      module_function

      # Get the frontmatter and plain content from a file
      # @param [String] path
      # @return [Array<Hash, String>]
      Contract IsA['Middleman::SourceFile'], Maybe[Symbol] => [Hash, Maybe[String]]
      def parse(source_file, frontmatter_delims, known_type = nil)
        full_path = source_file[:full_path]

        return [{}, nil] if ::Middleman::Util.binary?(full_path) || source_file[:types].include?(:binary)

        # Avoid weird race condition when a file is renamed
        begin
          # file = ::File.open(full_path.to_s)
          # first_line = file.gets
          
          # if first_line.match(/\A(?:[^\r\n]*coding:[^\r\n]*\r?\n)/)
          #   first_line = file.gets
          # end

          # file.close

          # possible_openers = possible_delim_openers(frontmatter_delims)
          # has_data_prefix = first_line.match(possible_openers)

          # return [{}, nil] if has_data_prefix.nil?

          content = source_file.read
        rescue EOFError, IOError, ::Errno::ENOENT
          return [{}, nil]
        end

        match = build_regex(frontmatter_delims).match(content) || {}

        unless match[:frontmatter]
          case known_type
          when :yaml
            return [parse_yaml(content, full_path), nil]
          when :json
            return [parse_json(content, full_path), nil]
          end
        end

        case [match[:start], match[:stop]]
        when *frontmatter_delims[:yaml]
          [
            parse_yaml(match[:frontmatter], full_path),
            match[:additional_content]
          ]
        when *frontmatter_delims[:json]
          [
            parse_json("{#{match[:frontmatter]}}", full_path),
            match[:additional_content]
          ]
        else
          [
            {},
            content
          ]
        end
      end

      def possible_delim_openers(frontmatter_delims)
        all_possible = frontmatter_delims
          .values
          .flatten(1)
          .map(&:first)
          .uniq
          
        /\A#{::Regexp.union(all_possible)}/
      end
      memoize :possible_delim_openers

      def build_regex(frontmatter_delims)
        start_delims, stop_delims = frontmatter_delims
                                    .values
                                    .flatten(1)
                                    .transpose
                                    .map(&::Regexp.method(:union))

        /
          \A(?:[^\r\n]*coding:[^\r\n]*\r?\n)?
          (?<start>#{start_delims})[ ]*\r?\n
          (?<frontmatter>.*?)[ ]*\r?\n?
          ^(?<stop>#{stop_delims})[ ]*\r?\n?
          \r?\n?
          (?<additional_content>.*)
        /mx
      end
      memoize :build_regex

      # Parse YAML frontmatter out of a string
      # @param [String] content
      # @return [Hash]
      Contract String, Pathname => Hash
      def parse_yaml(content, full_path)
        c = ::Middleman::Util.instrument 'parse.yaml' do
          ::YAML.load(content)
        end
        c ? symbolize_recursive(c) : {}
      rescue StandardError, ::Psych::SyntaxError => error
        warn "YAML Exception parsing #{full_path}: #{error.message}"
        {}
      end
      memoize :parse_yaml

      # Parse JSON frontmatter out of a string
      # @param [String] content
      # @return [Hash]
      Contract String, Pathname => Hash
      def parse_json(content, full_path)
        c = ::Middleman::Util.instrument 'parse.json' do
          ::JSON.parse(content)
        end
        c ? symbolize_recursive(c) : {}
      rescue StandardError => error
        warn "JSON Exception parsing #{full_path}: #{error.message}"
        {}
      end
      memoize :parse_json

      def symbolize_recursive(value)
        case value
        when Hash
          value.map { |k, v| [k.to_sym, symbolize_recursive(v)] }.to_h
        when Array
          value.map { |v| symbolize_recursive(v) }
        else
          value
        end
      end
    end
  end
end
