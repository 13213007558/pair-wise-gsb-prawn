# frozen_string_literal: true

require_relative 'fragment'

module Prawn
  module Text
    module Formatted
      # A fragment produced by applying the bidirectional algorithm to a line.
      #
      # It shares formatting with its source fragment but preserves the source
      # text in logical order.
      # @private
      class VisualFragment < Fragment
        attr_reader :logical_text
        attr_reader :logical_positions

        def self.from_positions(source, positions, document)
          logical_positions = positions.sort_by(&:index)
          visual_text = positions.map do |position|
            position.mirror ? Prawn::Text::Bidi::MIRRORED[position.char] : position.char
          end.join
          fragment = allocate
          fragment.send(:initialize_visual, source, visual_text, logical_positions, document)
          fragment
        end

        def rtl?
          @visual_level.odd?
        end

        def glyph_positions
          logical_positions.map do |position|
            {
              fragment: position.fragment,
              fragment_index: position.fragment_index,
              logical_index: position.index,
              level: position.level,
            }
          end
        end

        def trailing?
          logical_positions.any?(&:trailing)
        end

        private

        def initialize_visual(source, text, positions, document)
          @format_state = source.format_state.dup
          @document = document
          @word_spacing = source.word_spacing
          @original_text = source.original_text
          @logical_text = positions.map(&:char).join
          @logical_positions = positions
          @visual_level = positions.map(&:level).min
          @text = text
          @width = [
            positions.sum(&:width) -
              (positions.last.trailing ? source.character_spacing : 0),
            0,
          ].max
          self.line_height = source.line_height
          self.descender = source.descender
          self.ascender = source.ascender
        end
      end
    end
  end
end
