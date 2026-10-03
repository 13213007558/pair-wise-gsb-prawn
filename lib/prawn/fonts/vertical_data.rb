# frozen_string_literal: true

module Prawn
  module Fonts
    # Vertical metrics and OpenType glyph substitutions for an SFNT font.
    #
    # @private
    class VerticalData
      class UnsupportedFont < StandardError
        MESSAGE =
          'vertical writing requires an embedded TTF/OTF font with vhea '
          'and vmtx tables'

        def initialize(message = MESSAGE)
          super
        end
      end

      VERTICAL_FEATURES = %w[vrt2 vert].freeze

      attr_reader :substitutions

      def initialize(ttf)
        @ttf = ttf
        @substitutions = {}

        read_vertical_metrics
        read_vertical_origins
        read_gsub_substitutions
      end

      def glyph_id(char)
        char&.codepoints&.first && cmap[char.codepoints.first]
      end

      def substitute(glyph_id)
        substitutions[glyph_id] || glyph_id
      end

      def advance_height(glyph_id)
        advance_heights[glyph_id] || vertical_header[:advance_height_max]
      end

      def top_side_bearing(glyph_id)
        top_side_bearings[glyph_id] || vertical_header[:ascent]
      end

      def vertical_origin_y(glyph_id)
        vertical_origins.fetch(
          glyph_id,
          vertical_header[:ascent] - top_side_bearing(glyph_id),
        )
      end

      private

      attr_reader :vertical_header, :advance_heights, :top_side_bearings,
        :vertical_origins

      def cmap
        @cmap ||= @ttf.cmap.unicode.first
      end

      def tables
        @ttf.directory.tables
      end

      def with_table(tag)
        info = tables[tag]
        return unless info

        table = @ttf.contents
        table.rewind
        table.seek(info[:offset])
        yield(table, info[:length])
      end

      def require_table!(tag)
        raise UnsupportedFont unless tables.key?(tag)
      end

      def read_vertical_metrics
        require_table!('vhea')
        require_table!('vmtx')

        with_table('vhea') do |table|
          table.read(4)
          ascent, descent, line_gap = table.read(6).unpack('s>*')
          advance_height_max = table.read(2).unpack1('n')
          table.read(20)
          number_of_long_metrics = table.read(2).unpack1('n')
          @vertical_header = {
            ascent: ascent,
            descent: descent,
            line_gap: line_gap,
            advance_height_max: advance_height_max,
            number_of_long_metrics: number_of_long_metrics,
          }
        end

        glyph_count = @ttf.maximum_profile.num_glyphs
        advance_height_max = vertical_header[:advance_height_max]
        ascent = vertical_header[:ascent]
        @advance_heights = Array.new(glyph_count, advance_height_max)
        @top_side_bearings = Array.new(glyph_count, ascent)

        with_table('vmtx') do |table|
          vertical_header[:number_of_long_metrics].times do |glyph_id|
            advance_height, bearing = table.read(4).unpack('n s>')
            @advance_heights[glyph_id] = advance_height
            @top_side_bearings[glyph_id] = bearing
          end

          (vertical_header[:number_of_long_metrics]...glyph_count).each do
            |glyph_id|
            @top_side_bearings[glyph_id] = table.read(2).unpack1('s>')
          end
        end
      end

      def read_vertical_origins
        @vertical_origins = {}
        with_table('VORG') do |table|
          table.read(4)
          default_y = table.read(2).unpack1('s>')
          origin_count = table.read(2).unpack1('n')
          @vertical_origins.default = default_y
          origin_count.times do
            glyph_id, y = table.read(4).unpack('n s>')
            @vertical_origins[glyph_id] = y
          end
        end
      end

      def read_gsub_substitutions
        return unless tables.key?('GSUB')

        with_table('GSUB') do |table, _length|
          start = table.pos
          table_start = start
          major_minor, script_list, feature_list, lookup_list =
            table.read(10).unpack('Nn3')
          major = major_minor >> 16
          minor = major_minor & 0xFFFF
          next unless major == 1 && [0, 1].include?(minor)

          lookup_indices = VERTICAL_FEATURES.flat_map do |feature_tag|
            gsub_lookup_indices(
              table,
              table_start,
              feature_list,
              lookup_list,
              feature_tag,
            )
          end.uniq
          lookup_indices.each do |lookup_index|
            parse_gsub_lookup(table, table_start + lookup_list, lookup_index)
          end
        end
      end

      def gsub_lookup_indices(table, start, feature_list, lookup_list, tag)
        saved = table.pos
        table.seek(start + feature_list)
        count = table.read(2).unpack1('n')
        features = count.times.map { table.read(6).unpack('a4 n') }
        _offset = features.find { |feature_tag, _| feature_tag == tag }&.last
        return [] unless _offset

        table.seek(start + feature_list + _offset)
        table.read(4)
        lookup_count = table.read(2).unpack1('n')
        table.read(lookup_count * 2).unpack('n*')
      ensure
        table.seek(saved)
      end

      def parse_gsub_lookup(table, lookup_list_offset, lookup_index)
        saved = table.pos
        table.seek(lookup_list_offset)
        count = table.read(2).unpack1('n')
        return unless lookup_index < count

        table.seek(lookup_list_offset + 2 + lookup_index * 2)
        offset = table.read(2).unpack1('n')
        lookup_offset = lookup_list_offset + offset

        table.seek(lookup_offset)
        lookup_type = table.read(2).unpack1('n')
        return unless lookup_type == 1

        table.read(2)
        subtable_count = table.read(2).unpack1('n')
        offsets = table.read(subtable_count * 2).unpack('n*')
        offsets.each { |subtable_offset|
          parse_single_substitution(table, lookup_offset + subtable_offset)
        }
      ensure
        table.seek(saved)
      end

        def parse_single_substitution(table, offset)
          saved = table.pos
        table.seek(offset)
        format = table.read(2).unpack1('n')
        coverage_offset = table.read(2).unpack1('n')

        case format
        when 1
          delta_format = table.read(2).unpack1('n')
          glyph_count = table.read(2).unpack1('n')
          deltas = table.read(glyph_count * 2).unpack(
            delta_format == 1 ? 's>*' : 'n*',
          )
          parse_coverage(table, offset + coverage_offset).each_with_index do
            |glyph_id, index|
            substitutions[glyph_id] = glyph_id + deltas[index]
          end
        when 2
          glyph_count = table.read(2).unpack1('n')
          replacements = table.read(glyph_count * 2).unpack('n*')
          parse_coverage(table, offset + coverage_offset).each_with_index do
            |glyph_id, index|
            substitutions[glyph_id] = replacements[index]
          end
        end
      ensure
        table.seek(saved)
      end

      def parse_coverage(table, offset)
        saved = table.pos
        table.seek(offset)
        format = table.read(2).unpack1('n')
        count = table.read(2).unpack1('n')

        if format == 1
          table.read(count * 2).unpack('n*')
        elsif format == 2
          count.times.flat_map do
            first, last, _index = table.read(6).unpack('n3')
            (first..last).to_a
          end
        else
          []
        end
      ensure
        table.seek(saved)
      end
    end
  end
end
