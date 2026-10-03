# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # A positioned glyph in vertical writing mode.
      #
      # @private
      class VerticalRun
        attr_reader :character, :glyph_id, :rotated, :x, :y,
          :width, :height, :advance, :fragment

        def initialize(character, hash, glyph_id, rotated, x, y, width, height,
          advance, document)
          @character = character
          @glyph_id = glyph_id
          @rotated = rotated
          @x = x
          @y = y
          @width = width
          @height = height
          @advance = advance
          format_state = hash.dup
          format_state.delete(:text)
          @fragment = Fragment.new(character, format_state, document)
          @fragment.left = x
          @fragment.baseline = y
          @fragment.width = width
          @fragment.line_height = document.font.height
          if rotated
            @fragment.ascender = advance / 2.0
            @fragment.descender = advance / 2.0
          else
            @fragment.ascender = height
            @fragment.descender = 0
          end
        end
      end
    end
  end
end
