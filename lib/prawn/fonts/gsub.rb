# frozen_string_literal: true

module Prawn
  module Fonts
    # Minimal GSUB (Glyph Substitution) table parser.
    #
    # It only extracts vertical glyph substitutions: the vert (Vertical
    # Writing) and vrt2 (Vertical Alternates and Rotation) features, and only
    # single substitution lookups. That is enough to pick the glyphs a font
    # designer designated for vertical typesetting (e.g. upright brackets and
    # punctuation).
    #
    # @note You shouldn't use this class directly. It's used by {Fonts::TTF}.
    class GSUB
      # GSUB table tag.
      TAG = 'GSUB'

      # Feature tags considered for vertical glyph substitution, in order of
      # increasing priority. Per the OpenType spec, vrt2 (when present)
      # supersedes vert.
      VERTICAL_FEATURES = %w[vert vrt2].freeze

      # Single substitution lookup type.
      SINGLE_SUBSTITUTION = 1

      # Extract vertical glyph substitutions from a font file.
      #
      # @param ttf [TTFunk::File]
      # @return [Prawn::Fonts::GSUB, nil]
      #   nil if the font doesn't contain a GSUB table.
      def self.for(ttf)
        table = ttf.directory.tables[TAG]
        return nil unless table

        new(ttf.contents.string[table[:offset], table[:length]])
      end

      # @param data [String] GSUB table contents
      def initialize(data)
        @data = data
      end

      # Get the vertical variant of a glyph.
      #
      # @param glyph_id [Integer] glyph ID in the font
      # @return [Integer, nil]
      #   glyph ID of the vertical variant, or nil if the font doesn't
      #   designate one
      def substitute(glyph_id)
        substitutions[glyph_id]
      end

      private

      def substitutions
        @substitutions ||= build_substitutions
      end

      def build_substitutions
        return {} if @data.bytesize < 10

        major_version, _minor, _script_list, feature_list, lookup_list =
          @data.unpack('n5')
        return {} unless major_version == 1

        result = {}

        VERTICAL_FEATURES.each do |tag|
          feature_offset(feature_list, tag)&.then do |offset|
            each_lookup_index(feature_list + offset) do |lookup_index|
              parse_lookup(lookup_list, lookup_index, result)
            end
          end
        end

        result
      end

      # Find the offset of the feature table for the given tag, relative to
      # the start of the feature list.
      def feature_offset(feature_list_offset, tag)
        count = ushort(feature_list_offset)

        count.times do |i|
          record = feature_list_offset + 2 + (i * 6)
          return ushort(record + 4) if @data[record, 4] == tag
        end

        nil
      end

      def each_lookup_index(feature_offset)
        count = ushort(feature_offset + 2)

        count.times do |i|
          yield ushort(feature_offset + 4 + (i * 2))
        end
      end

      def parse_lookup(lookup_list_offset, index, result)
        count = ushort(lookup_list_offset)
        return if index >= count

        lookup_offset =
          lookup_list_offset + ushort(lookup_list_offset + 2 + (index * 2))
        lookup_type = ushort(lookup_offset)
        return unless lookup_type == SINGLE_SUBSTITUTION

        subtable_count = ushort(lookup_offset + 4)

        subtable_count.times do |i|
          subtable_offset = lookup_offset + ushort(lookup_offset + 6 + (i * 2))
          parse_single_substitution(subtable_offset, result)
        end
      end

      def parse_single_substitution(offset, result)
        coverage = parse_coverage(offset + ushort(offset + 2))

        case ushort(offset)
        when 1
          delta = short(offset + 4)
          coverage.each do |glyph_id|
            result[glyph_id] = (glyph_id + delta) & 0xFFFF
          end
        when 2
          count = ushort(offset + 4)
          coverage.each_with_index do |glyph_id, i|
            break if i >= count

            result[glyph_id] = ushort(offset + 6 + (i * 2))
          end
        end
      end

      def parse_coverage(offset)
        case ushort(offset)
        when 1
          count = ushort(offset + 2)
          @data[offset + 4, count * 2].unpack('n*')
        when 2
          count = ushort(offset + 2)
          glyphs = []

          count.times do |i|
            first, last = @data[offset + 4 + (i * 6), 4].unpack('n n')
            glyphs.concat((first..last).to_a)
          end

          glyphs
        else
          []
        end
      end

      def ushort(offset)
        @data[offset, 2].unpack1('n')
      end

      def short(offset)
        value = ushort(offset)
        value >= 0x8000 ? value - 0x10000 : value
      end
    end
  end
end
