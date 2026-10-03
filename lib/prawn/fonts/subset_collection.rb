# frozen_string_literal: true

require 'ttfunk'
require 'ttfunk/subset_collection'

module Prawn
  module Fonts
    # A font subset that maps character codes to explicitly chosen glyph IDs.
    #
    # Regular subsets derive glyphs from the font cmap. Vertical typesetting
    # needs to render GSUB-substituted glyphs (e.g. vertical variants of
    # brackets) that are not reachable through the cmap, so this subset keeps
    # an explicit code to glyph mapping. The ToUnicode map still points to the
    # original characters so text extraction keeps working.
    #
    # @note You shouldn't use this class directly. It's used by {Fonts::TTF}.
    class VerticalGlyphSubset < TTFunk::Subset::Base
      # First usable character code. Apparently, PDFs don't like to use codes
      # between 0 and 31.
      FIRST_CODE = 0x21

      # Last usable character code (single-byte encoding).
      LAST_CODE = 0xFF

      # @param original [TTFunk::File]
      def initialize(original)
        super
        # The space character must always be included in a subset.
        @code_to_glyph = { 0x20 => unicode_cmap[0x20] }
        @code_to_unicode = { 0x20 => 0x20 }
        @pair_to_code = {}
        @next_code = FIRST_CODE
      end

      # Is this a Unicode-based subset?
      #
      # @return [true]
      def unicode?
        true
      end

      # Get a mapping from this subset to Unicode.
      #
      # @return [Hash{Integer => Integer}]
      def to_unicode_map
        @code_to_unicode.dup
      end

      # Vertical glyph subsets never claim characters during regular
      # encoding; glyphs are only added via {\#code_for}.
      #
      # @param _character [Integer]
      # @return [false]
      def covers?(_character)
        false
      end

      # @param _character [Integer]
      # @return [false]
      def includes?(_character)
        false
      end

      # @param _character [Integer]
      # @return [void]
      def use(_character)
        # no-op: glyphs are added explicitly with #code_for
      end

      # Can this subset accommodate another glyph?
      #
      # @return [Boolean]
      def full?
        @next_code > LAST_CODE
      end

      # Is the Unicode codepoint and glyph ID pair already in this subset?
      #
      # @param unicode [Integer] Unicode codepoint
      # @param glyph_id [Integer] glyph ID in the original font
      # @return [Boolean]
      def pair_included?(unicode, glyph_id)
        @pair_to_code.key?([unicode, glyph_id])
      end

      # Get the character code for the Unicode codepoint rendered with the
      # given glyph, registering it in the subset if necessary.
      #
      # @param unicode [Integer] Unicode codepoint
      # @param glyph_id [Integer] glyph ID in the original font
      # @return [Integer, nil] character code, or nil if the subset is full
      def code_for(unicode, glyph_id)
        pair = [unicode, glyph_id]
        return @pair_to_code[pair] if @pair_to_code.key?(pair)
        return nil if full?

        code = @next_code
        @next_code += 1
        @pair_to_code[pair] = code
        @code_to_glyph[code] = glyph_id
        @code_to_unicode[code] = unicode
        code
      end

      # Get cmap table for this subset.
      #
      # @return [TTFunk::Table::Cmap]
      def new_cmap_table
        @new_cmap_table ||=
          TTFunk::Table::Cmap.encode(@code_to_glyph, :mac_roman)
      end

      # Get the list of glyph IDs from the original font that are in this
      # subset.
      #
      # @return [Array<Integer>]
      def original_glyph_ids
        ([0] + @code_to_glyph.values).uniq.sort
      end
    end

    # Font subset collection that can additionally encode explicitly chosen
    # glyphs (used for vertical glyph substitution).
    #
    # @note You shouldn't use this class directly. It's used by {Fonts::TTF}.
    class SubsetCollection < TTFunk::SubsetCollection
      # Encode characters, using explicitly chosen glyphs where provided.
      #
      # @param pairs [Array<Array(Integer, Integer, nil)>]
      #   pairs of Unicode codepoint and glyph ID (or nil to use the regular
      #   cmap-derived glyph)
      # @return [Array<Array(Integer, String)>] subset chunks
      def encode_glyph_pairs(pairs)
        chunks = []
        pending = []

        flush = lambda do
          next if pending.empty?

          encode(pending).each do |(subset, string)|
            append_chunk(chunks, subset, string)
          end
          pending = []
        end

        pairs.each do |(codepoint, glyph_id)|
          if glyph_id.nil?
            pending << codepoint
          else
            flush.call
            subset = vertical_subset_for(codepoint, glyph_id)
            code = subset.code_for(codepoint, glyph_id)
            append_chunk(chunks, @subsets.index(subset), code.chr.b)
          end
        end

        flush.call
        chunks
      end

      private

      def append_chunk(chunks, subset, string)
        if chunks.any? && chunks.last[0] == subset
          chunks.last[1] << string
        else
          chunks << [subset, string]
        end
      end

      def vertical_subset_for(codepoint, glyph_id)
        @vertical_subsets ||= []

        subset =
          @vertical_subsets.find { |s|
            s.pair_included?(codepoint, glyph_id)
          } || @vertical_subsets.find { |s| !s.full? }

        unless subset
          subset = VerticalGlyphSubset.new(@original)
          @vertical_subsets << subset
          @subsets << subset
        end

        subset
      end
    end
  end
end
