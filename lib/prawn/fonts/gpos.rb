# frozen_string_literal: true

# prawn/fonts/gpos.rb : Minimal OpenType GPOS (Glyph Positioning) support
#
# This is free software. Please see the LICENSE and COPYING files for details.

module Prawn
  module Fonts
    # Reads the OpenType GPOS table and applies glyph positioning adjustments.
    #
    # Supported lookup types:
    # * 2 - Pair Adjustment (PairPos), formats 1 and 2
    # * 4 - Mark-to-Base Attachment
    # * 6 - Mark-to-Mark Attachment
    #
    # All positioning values are in font units.
    #
    # @private
    class GPOS
      # Features applied by default when GPOS positioning is enabled.
      DEFAULT_FEATURES = %w[kern mark mkmk].freeze

      # ValueRecord field bits in the order they appear in the record.
      VALUE_FIELDS = [
        [0x0001, :x_placement],
        [0x0002, :y_placement],
        [0x0004, :x_advance],
        [0x0008, :y_advance],
      ].freeze

      # Number of bytes a ValueRecord with the given format occupies,
      # including device/variation offsets (which are skipped, not used).
      def self.value_record_size(format)
        (0..7).count { |bit| (format & (1 << bit)) != 0 } * 2
      end

      # @param data [String] raw GPOS table bytes
      def initialize(data)
        @data = data

        parse_script_list(u16(4))
        parse_feature_list(u16(6))
        parse_lookup_list(u16(8))
      end

      # Indices of lookups selected for the given script, language, and
      # features, in application order: features are applied in the order
      # they are given (e.g. "kern" before "mark" before "mkmk"), and the
      # lookups of each feature are applied in lookup list order. Each
      # lookup is applied at most once even if several features reference
      # it.
      #
      # @param script [String, nil] OpenType script tag (e.g. "latn").
      #   When nil, "DFLT" is preferred, then "latn", then the first script.
      # @param language [String, nil] OpenType language system tag
      #   (e.g. "ENG "). When nil, the script's default language system
      #   is used.
      # @param features [Array<String>] OpenType feature tags to apply.
      # @return [Array<Integer>]
      def lookup_indices(script: nil, language: nil, features: DEFAULT_FEATURES)
        script_table = select_script(script)
        return [] unless script_table

        lang_sys =
          if language
            script_table[:languages][normalize_tag(language)] || script_table[:default]
          else
            script_table[:default]
          end
        return [] unless lang_sys

        lang_features = lang_sys[:feature_indices].map { |i| @features[i] }.compact

        Array(features)
          .map { |f| normalize_tag(f) }
          .flat_map { |tag|
            feature = lang_features.find { |f| f[:tag] == tag }
            feature ? feature[:lookup_indices] : []
          }
          .uniq
      end

      # Apply GPOS positioning to a sequence of glyphs.
      #
      # The glyph-to-character correspondence is preserved: the returned
      # array has exactly one entry per input glyph, in the same order.
      #
      # @param glyphs [Array<Integer>] glyph IDs
      # @param advances [Array<Numeric>] horizontal advances in font units
      # @param script [String, nil]
      # @param language [String, nil]
      # @param features [Array<String>]
      # @return [Array<Hash>] per-glyph hashes with keys :gid, :advance,
      #   :x_offset, :y_offset (all positioning values in font units).
      #   Marks attached by MarkToBase/MarkToMark lookups get their advance
      #   zeroed so they don't add to the line width.
      def position(glyphs, advances, script: nil, language: nil, features: DEFAULT_FEATURES)
        positioned = glyphs.each_with_index.map do |gid, i|
          { gid: gid, advance: advances[i], x_offset: 0, y_offset: 0 }
        end

        lookup_indices(script: script, language: language, features: features).each do |index|
          lookup = @lookups[index]
          next unless lookup

          lookup[:subtables].each do |subtable|
            case lookup[:type]
            when 2 then apply_pair_pos(subtable, positioned)
            when 4 then apply_mark_to_base(subtable, positioned)
            when 6 then apply_mark_to_mark(subtable, positioned)
            end
          end
        end

        positioned
      end

      private

      def u16(offset)
        @data.byteslice(offset, 2).unpack1('n')
      end

      def s16(offset)
        @data.byteslice(offset, 2).unpack1('s>')
      end

      def tag_at(offset)
        @data.byteslice(offset, 4)
      end

      def normalize_tag(tag)
        tag.to_s.ljust(4)[0, 4]
      end

      def select_script(tag)
        return nil if @scripts.empty?

        if tag
          @scripts[normalize_tag(tag)]
        else
          @scripts['DFLT'] || @scripts['latn'] || @scripts.values.first
        end
      end

      # --- Table parsing -------------------------------------------------

      def parse_script_list(offset)
        count = u16(offset)
        @scripts = {}
        count.times do |i|
          record = offset + 2 + (i * 6)
          @scripts[tag_at(record)] = parse_script(offset + u16(record + 4))
        end
      end

      def parse_script(offset)
        default_offset = u16(offset)
        lang_count = u16(offset + 2)
        languages = {}
        lang_count.times do |i|
          record = offset + 4 + (i * 6)
          languages[tag_at(record)] = parse_lang_sys(offset + u16(record + 4))
        end
        {
          default: default_offset.zero? ? nil : parse_lang_sys(offset + default_offset),
          languages: languages,
        }
      end

      def parse_lang_sys(offset)
        required = u16(offset + 2)
        count = u16(offset + 4)
        {
          required_feature: required == 0xFFFF ? nil : required,
          feature_indices: count.times.map { |i| u16(offset + 6 + (i * 2)) },
        }
      end

      def parse_feature_list(offset)
        count = u16(offset)
        @features =
          count.times.map do |i|
            record = offset + 2 + (i * 6)
            parse_feature(offset + u16(record + 4), tag_at(record))
          end
      end

      def parse_feature(offset, tag)
        count = u16(offset + 2)
        {
          tag: tag,
          lookup_indices: count.times.map { |i| u16(offset + 4 + (i * 2)) },
        }
      end

      def parse_lookup_list(offset)
        count = u16(offset)
        @lookups =
          count.times.map do |i|
            parse_lookup(offset + u16(offset + 2 + (i * 2)))
          end
      end

      def parse_lookup(offset)
        type = u16(offset)
        count = u16(offset + 4)
        subtable_offsets = count.times.map { |i| offset + u16(offset + 6 + (i * 2)) }

        subtables =
          case type
          when 2 then subtable_offsets.map { |o| parse_pair_pos(o) }
          when 4 then subtable_offsets.map { |o| parse_mark_to_base(o) }
          when 6 then subtable_offsets.map { |o| parse_mark_to_mark(o) }
          else []
          end

        { type: type, flag: u16(offset + 2), subtables: subtables }
      end

      def parse_pair_pos(offset)
        case u16(offset)
        when 1
          value_format1 = u16(offset + 4)
          value_format2 = u16(offset + 6)
          count = u16(offset + 8)
          {
            format: 1,
            coverage: parse_coverage(offset + u16(offset + 2)),
            pair_sets: count.times.map { |i|
              parse_pair_set(offset + u16(offset + 10 + (i * 2)), value_format1, value_format2)
            },
          }
        when 2
          value_format1 = u16(offset + 4)
          value_format2 = u16(offset + 6)
          class1_count = u16(offset + 12)
          class2_count = u16(offset + 14)
          value1_size = GPOS.value_record_size(value_format1)
          value2_size = GPOS.value_record_size(value_format2)

          matrix = []
          pos = offset + 16
          class1_count.times do
            row = []
            class2_count.times do
              value1 = read_value_record(pos, value_format1)
              value2 = read_value_record(pos + value1_size, value_format2)
              row << [value1, value2]
              pos += value1_size + value2_size
            end
            matrix << row
          end

          {
            format: 2,
            coverage: parse_coverage(offset + u16(offset + 2)),
            class_def1: parse_class_def(offset + u16(offset + 8)),
            class_def2: parse_class_def(offset + u16(offset + 10)),
            matrix: matrix,
          }
        else
          { format: :unsupported }
        end
      end

      def parse_pair_set(offset, value_format1, value_format2)
        count = u16(offset)
        value1_size = GPOS.value_record_size(value_format1)
        record_size = 2 + value1_size + GPOS.value_record_size(value_format2)

        pairs = {}
        count.times do |i|
          pos = offset + 2 + (i * record_size)
          pairs[u16(pos)] = [
            read_value_record(pos + 2, value_format1),
            read_value_record(pos + 2 + value1_size, value_format2),
          ]
        end
        pairs
      end

      def read_value_record(offset, format)
        record = { x_placement: 0, y_placement: 0, x_advance: 0, y_advance: 0 }
        pos = offset
        VALUE_FIELDS.each do |bit, name|
          next if (format & bit).zero?

          record[name] = s16(pos)
          pos += 2
        end
        record
      end

      def parse_coverage(offset)
        case u16(offset)
        when 1
          count = u16(offset + 2)
          {
            format: 1,
            glyphs: count.times.map { |i| u16(offset + 4 + (i * 2)) },
          }
        when 2
          count = u16(offset + 2)
          {
            format: 2,
            ranges: count.times.map { |i|
              record = offset + 4 + (i * 6)
              { start: u16(record), end: u16(record + 2), index: u16(record + 4) }
            },
          }
        else
          { format: :unsupported }
        end
      end

      def parse_class_def(offset)
        case u16(offset)
        when 1
          count = u16(offset + 4)
          {
            format: 1,
            start: u16(offset + 2),
            classes: count.times.map { |i| u16(offset + 6 + (i * 2)) },
          }
        when 2
          count = u16(offset + 2)
          {
            format: 2,
            ranges: count.times.map { |i|
              record = offset + 4 + (i * 6)
              { start: u16(record), end: u16(record + 2), class: u16(record + 4) }
            },
          }
        else
          { format: :unsupported }
        end
      end

      def parse_mark_to_base(offset)
        class_count = u16(offset + 6)
        {
          format: 1,
          mark_coverage: parse_coverage(offset + u16(offset + 2)),
          base_coverage: parse_coverage(offset + u16(offset + 4)),
          marks: parse_mark_array(offset + u16(offset + 8)),
          bases: parse_anchor_matrix(offset + u16(offset + 10), class_count),
        }
      end

      def parse_mark_to_mark(offset)
        class_count = u16(offset + 6)
        {
          format: 1,
          mark1_coverage: parse_coverage(offset + u16(offset + 2)),
          mark2_coverage: parse_coverage(offset + u16(offset + 4)),
          marks: parse_mark_array(offset + u16(offset + 8)),
          marks2: parse_anchor_matrix(offset + u16(offset + 10), class_count),
        }
      end

      def parse_mark_array(offset)
        count = u16(offset)
        count.times.map do |i|
          record = offset + 2 + (i * 4)
          {
            class: u16(record),
            anchor: parse_anchor(offset + u16(record + 2)),
          }
        end
      end

      def parse_anchor_matrix(offset, class_count)
        count = u16(offset)
        count.times.map do |i|
          class_count.times.map do |c|
            anchor_offset = u16(offset + 2 + (((i * class_count) + c) * 2))
            anchor_offset.zero? ? nil : parse_anchor(offset + anchor_offset)
          end
        end
      end

      def parse_anchor(offset)
        { x: s16(offset + 2), y: s16(offset + 4) }
      end

      # --- Lookup application --------------------------------------------

      def coverage_index(coverage, gid)
        case coverage[:format]
        when 1
          coverage[:glyphs].index(gid)
        when 2
          range = coverage[:ranges].find { |r| gid >= r[:start] && gid <= r[:end] }
          range && range[:index] + (gid - range[:start])
        end
      end

      def class_def_value(class_def, gid)
        case class_def[:format]
        when 1
          index = gid - class_def[:start]
          if index >= 0 && index < class_def[:classes].length
            class_def[:classes][index]
          else
            0
          end
        when 2
          range = class_def[:ranges].find { |r| gid >= r[:start] && gid <= r[:end] }
          range ? range[:class] : 0
        else
          0
        end
      end

      def apply_pair_pos(subtable, positioned)
        (0...(positioned.length - 1)).each do |i|
          coverage = coverage_index(subtable[:coverage], positioned[i][:gid])
          next unless coverage

          values =
            case subtable[:format]
            when 1
              pair_set = subtable[:pair_sets][coverage]
              pair_set && pair_set[positioned[i + 1][:gid]]
            when 2
              class1 = class_def_value(subtable[:class_def1], positioned[i][:gid])
              class2 = class_def_value(subtable[:class_def2], positioned[i + 1][:gid])
              row = subtable[:matrix][class1]
              row && row[class2]
            end
          next unless values

          apply_value(positioned[i], values[0])
          apply_value(positioned[i + 1], values[1])
        end
      end

      def apply_value(glyph, value)
        glyph[:x_offset] += value[:x_placement]
        glyph[:y_offset] += value[:y_placement]
        glyph[:advance] += value[:x_advance]
      end

      def apply_mark_to_base(subtable, positioned)
        positioned.each_with_index do |glyph, i|
          mark_index = coverage_index(subtable[:mark_coverage], glyph[:gid])
          next unless mark_index

          mark = subtable[:marks][mark_index]
          next unless mark && mark[:anchor]

          # Find the preceding base glyph, skipping over any marks.
          base_index = nil
          j = i - 1
          while j >= 0
            base_index = coverage_index(subtable[:base_coverage], positioned[j][:gid])
            break if base_index

            j -= 1
          end
          next unless base_index

          base_record = subtable[:bases][base_index]
          anchor = base_record && base_record[mark[:class]]
          next unless anchor

          attach(glyph, mark[:anchor], positioned, j, i, anchor)
        end
      end

      def apply_mark_to_mark(subtable, positioned)
        positioned.each_with_index do |glyph, i|
          next if i.zero?

          mark1_index = coverage_index(subtable[:mark1_coverage], glyph[:gid])
          next unless mark1_index

          mark1 = subtable[:marks][mark1_index]
          next unless mark1 && mark1[:anchor]

          j = i - 1
          mark2_index = coverage_index(subtable[:mark2_coverage], positioned[j][:gid])
          next unless mark2_index

          mark2_record = subtable[:marks2][mark2_index]
          anchor = mark2_record && mark2_record[mark1[:class]]
          next unless anchor

          attach(glyph, mark1[:anchor], positioned, j, i, anchor)
        end
      end

      # Position glyph +i+ so that its mark anchor coincides with the given
      # anchor of glyph +j+, and zero its advance so it doesn't add to the
      # line width.
      def attach(glyph, mark_anchor, positioned, j, i, anchor)
        advance_between = (j...i).sum { |k| positioned[k][:advance] }

        glyph[:x_offset] =
          positioned[j][:x_offset] + anchor[:x] - mark_anchor[:x] - advance_between
        glyph[:y_offset] =
          positioned[j][:y_offset] + anchor[:y] - mark_anchor[:y]
        glyph[:advance] = 0
      end
    end
  end
end
