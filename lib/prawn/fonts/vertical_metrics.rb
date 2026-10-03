# frozen_string_literal: true

module Prawn
  module Fonts
    # Vertical metrics (vhea and vmtx OpenType tables) of a font.
    #
    # TTFunk doesn't parse these tables so this is a minimal implementation
    # that reads them directly from the font file.
    #
    # @note You shouldn't use this class directly. It's used by {Fonts::TTF}.
    class VerticalMetrics
      # vhea table tag.
      VHEA_TAG = 'vhea'

      # vmtx table tag.
      VMTX_TAG = 'vmtx'

      # Length of the vhea table in bytes.
      VHEA_LENGTH = 36

      # Vertical typographic ascender.
      # @return [Integer]
      attr_reader :ascender

      # Vertical typographic descender.
      # @return [Integer]
      attr_reader :descender

      # Vertical typographic line gap.
      # @return [Integer]
      attr_reader :line_gap

      # Extract vertical metrics from a font file.
      #
      # @param ttf [TTFunk::File]
      # @return [Prawn::Fonts::VerticalMetrics, nil]
      #   nil if the font doesn't contain both vhea and vmtx tables.
      def self.for(ttf)
        tables = ttf.directory.tables
        return nil unless tables.key?(VHEA_TAG) && tables.key?(VMTX_TAG)

        new(
          ttf.contents.string,
          tables[VHEA_TAG],
          tables[VMTX_TAG],
          ttf.maximum_profile.num_glyphs,
        )
      end

      # @param data [String] font file contents
      # @param vhea [Hash] vhea table directory entry
      # @param vmtx [Hash] vmtx table directory entry
      # @param num_glyphs [Integer] number of glyphs in the font
      def initialize(data, vhea, vmtx, num_glyphs)
        header = data[vhea[:offset], VHEA_LENGTH].unpack('N n16')
        @ascender = signed(header[1])
        @descender = signed(header[2])
        @line_gap = signed(header[3])

        long_metrics_count = header[16]

        @advances = []
        @bearings = []

        long_metrics_count.times do |i|
          advance, bearing = data[vmtx[:offset] + (i * 4), 4].unpack('n n')
          @advances << advance
          @bearings << signed(bearing)
        end

        # Glyphs past the long metrics share the last advance and only have
        # their top side bearings recorded.
        (num_glyphs - long_metrics_count).times do |i|
          offset = vmtx[:offset] + (long_metrics_count * 4) + (i * 2)
          @advances << @advances.last
          @bearings << signed(data[offset, 2].unpack1('n'))
        end
      end

      # Vertical advance of the glyph (distance between the vertical origins
      # of consecutive glyphs).
      #
      # @param glyph_id [Integer]
      # @return [Integer]
      def advance_height(glyph_id)
        @advances[glyph_id] || @advances.last
      end

      # Top side bearing of the glyph.
      #
      # @param glyph_id [Integer]
      # @return [Integer]
      def top_side_bearing(glyph_id)
        @bearings[glyph_id] || @bearings.last
      end

      private

      def signed(value)
        value >= 0x8000 ? value - 0x10000 : value
      end
    end
  end
end
