# frozen_string_literal: true

module Prawn
  module Text
    module Vertical
      # A text fragment with its format resolved against the document fonts,
      # ready for vertical layout.
      #
      # @private
      class Fragment
        # Font object.
        # @return [Prawn::Fonts::Font]
        attr_reader :font

        # Font name to re-select the font for rendering.
        # @return [String, nil]
        attr_reader :font_name

        # Font style.
        # @return [Symbol]
        attr_reader :font_style

        # Font size.
        # @return [Number]
        attr_reader :size

        # Text color.
        # @return [Color, nil]
        attr_reader :color

        # Link URL.
        # @return [String, nil]
        attr_reader :link

        # Anchor destination.
        # @return [String, nil]
        attr_reader :anchor

        # Local file to open.
        # @return [String, nil]
        attr_reader :local

        # Character spacing.
        # @return [Number]
        attr_reader :character_spacing

        # Fragment text (normalized to the font encoding).
        # @return [String]
        attr_reader :text

        def initialize(attributes)
          @font = attributes.fetch(:font)
          @font_name = attributes[:font_name]
          @font_style = attributes.fetch(:font_style)
          @size = attributes.fetch(:size)
          @color = attributes[:color]
          @link = attributes[:link]
          @anchor = attributes[:anchor]
          @local = attributes[:local]
          @character_spacing = attributes.fetch(:character_spacing)
          @text = attributes.fetch(:text)
        end
      end
    end
  end
end
