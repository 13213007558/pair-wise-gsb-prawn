# frozen_string_literal: true

module Prawn
  module Fonts
    class TTF < ::Prawn::Font
      # Minimal GPOS reader used for PairPos, MarkToBase and MarkToMark.
      class Gpos
        Position = Struct.new(
          :x_placement, :y_placement, :x_advance, :x_origin,
          :attached_to, keyword_init: true
        )
        Run = Struct.new(
          :encoded, :positions, :step
        )

        def initialize(ttf, scale_factor)
          @ttf = ttf
          @scale_factor = scale_factor
          @info = ttf.directory_info('GPOS')
        end

        def supported?
          @info && read_u16(@info[:offset]) == 1 && read_u16(@info[:offset] + 2) == 0
        end

        def self.normalize_options(options)
          return nil unless options

          if options == true
            options = {
              script: :default, language: :default, features: %i[kern mark mkmk],
            }
          end
          options = options.dup
          options[:script] ||= :default
          options[:language] ||= :default
          unless options[:features] == :all
            options[:features] = Array(options[:features]).map(&:to_sym)
          end
          options
        end

        def apply(codepoints, cmap, options)
          options = self.class.normalize_options(options)
          glyphs = codepoints.map { |code| cmap[code] || 0 }
          positions = initial_positions(glyphs)

          selected_lookups(options).each { |lookup| apply_lookup(lookup, glyphs, positions) }
          assign_origins(positions)

          positions
        end

        def line_width(codepoints, cmap, options)
          apply(codepoints, cmap, options).sum(&:x_advance) * @scale_factor
        end

        private

        X_PLACEMENT = 0x0001
        Y_PLACEMENT = 0x0002
        X_ADVANCE = 0x0004
        Y_ADVANCE = 0x0008
        X_PLACEMENT_DEVICE = 0x0010
        Y_PLACEMENT_DEVICE = 0x0020
        X_ADVANCE_DEVICE = 0x0040
        Y_ADVANCE_DEVICE = 0x0080

        def initial_positions(glyphs)
          glyphs.map do |glyph|
            width = glyph.zero? ? 0 : @ttf.horizontal_metrics.widths[glyph]
            Position.new(
              x_placement: 0, y_placement: 0, x_advance: width.to_f,
              x_origin: 0, attached_to: nil,
            )
          end
        end

        def selected_lookups(options)
          script = find_script(options[:script])
          return [] unless script

          langsys = find_langsys(script, options[:language])
          return [] unless langsys

          enabled_feature_indices = langsys_feature_indices(langsys)
          indices = []
          feature_count = read_u16(feature_list_offset)
          feature_count.times do |index|
            next unless enabled_feature_indices.include?(index)

            record = feature_list_offset + (2 + (index * 6))
            tag = read_tag(record)
            if options[:features] == :all || options[:features].include?(tag.strip.to_sym)
              offset = read_u16(record + 4)
              lookup_indices = feature_lookup_indices(feature_list_offset + offset)
              indices.concat(lookup_indices)
            end
          end

          indices.uniq.sort.filter_map { |index| lookup(index) }
        end

        def find_script(tag)
          tags = script_tags(tag)
          count = read_u16(script_list_offset)
          count.times do |index|
            record = script_list_offset + 2 + (index * 8)
            offset = read_u32(record + 4)
            if tags.include?(read_tag(record)) && offset.positive?
              return script_list_offset + offset
            end
          end
          nil
        end

        def script_tags(tag)
          return ['DFLT', 'latn', 'Latn'] if tag.to_sym == :default

          [tag.to_s.ljust(4, ' ')]
        end

        def find_langsys(script, language)
          if language.to_s == 'default'
            offset = read_u16(script)
            return offset.zero? ? nil : script + offset
          end

          tag = language.to_s.ljust(4, ' ')
          count = read_u16(script + 2)
          count.times do |index|
            record = script + 4 + (index * 6)
            if read_tag(record) == tag
              offset = read_u16(record + 4)
              return offset.zero? ? nil : script + offset
            end
          end
          nil
        end

        def langsys_feature_indices(langsys)
          required = read_u16(langsys + 4)
          indices = required == 0xFFFF ? [] : [required]
          count = read_u16(langsys + 6)
          count.times { |index| indices << read_u16(langsys + 8 + (index * 2)) }
          indices
        end

        def lookup(index)
          offset = read_u16(lookup_list_offset + 2 + (index * 2))
          return nil if offset.zero?

          base = lookup_list_offset + offset
          { base: base, type: read_u16(base), subtables: subtable_offsets(base) }
        end

        def subtable_offsets(lookup_base)
          count = read_u16(lookup_base + 4)
          count.times.map do |index|
            offset = read_u16(lookup_base + 6 + (index * 2))
            offset.zero? ? nil : lookup_base + offset
          end.compact
        end

        def feature_lookup_indices(base)
          count = read_u16(base + 2)
          count.times.map { |index| read_u16(base + 4 + (index * 2)) }
        end

        def apply_lookup(lookup, glyphs, positions)
          @current_glyphs = glyphs
          @current_positions = positions
          lookup[:subtables].each do |subtable|
            case lookup[:type]
            when 2
              apply_pair_pos(subtable)
            when 4
              apply_mark_to_base(subtable)
            when 6
              apply_mark_to_mark(subtable)
            end
          end
        end

        def apply_pair_pos(base)
          format = read_u16(base)
          if format == 1
            apply_pair_pos_format1(base)
          elsif format == 2
            apply_pair_pos_format2(base)
          end
        end

        def apply_pair_pos_format1(base)
          coverage = field_absolute(base, read_u16(base + 2))
          value_format1 = read_u16(base + 4)
          value_format2 = read_u16(base + 6)
          set_count = read_u16(base + 8)
          cursor = base + 10
          sets = set_count.times.map do
            offset = read_u16(cursor)
            cursor += 2
            offset.zero? ? nil : base + offset
          end

          each_pair_position do |index|
            coverage_index = coverage_index(coverage, @current_glyphs[index])
            next unless coverage_index

            set = sets[coverage_index]
            next unless set

            pair_count = read_u16(set)
            pair_count.times do |pair_index|
              pair = set + 2 + (pair_index * (2 + value_record_size(value_format1) + value_record_size(value_format2)))
              next unless @current_glyphs[index + 1] == read_u16(pair)

              first = pair + 2
              second = first + value_record_size(value_format1)
              apply_value_record(value_format1, first, @current_positions[index])
              apply_value_record(value_format2, second, @current_positions[index + 1])
              break
            end
          end
        end

        def apply_pair_pos_format2(base)
          coverage = field_absolute(base, read_u16(base + 2))
          class_def1 = field_absolute(base, read_u16(base + 4))
          class_def2 = field_absolute(base, read_u16(base + 6))
          value_format1 = read_u16(base + 8)
          value_format2 = read_u16(base + 10)
          class1_count = read_u16(base + 12)
          class2_count = read_u16(base + 14)
          record_size = value_record_size(value_format1) + value_record_size(value_format2)
          table = base + 18

          each_pair_position do |index|
            first_class = class_membership(class_def1, @current_glyphs[index], coverage)
            second_class = class_membership(class_def2, @current_glyphs[index + 1])
            next unless first_class && second_class
            next unless first_class.positive? && first_class <= class1_count
            next unless second_class.positive? && second_class <= class2_count

            record = table + (((first_class - 1) * class2_count) + (second_class - 1)) * record_size
            apply_value_record(value_format1, record, @current_positions[index])
            apply_value_record(value_format2, record + value_record_size(value_format1), @current_positions[index + 1])
          end
        end

        def apply_mark_to_base(base)
          return unless read_u16(base) == 1

          mark_coverage = field_absolute(base, read_u16(base + 2))
          base_coverage = field_absolute(base, read_u16(base + 4))
          mark_class_count = read_u16(base + 6)
          mark_array = field_absolute(base, read_u16(base + 8))
          base_array = field_absolute(base, read_u16(base + 10))
          mark_records = read_mark_records(mark_array)

          previous_base = nil
          @current_glyphs.each_with_index do |glyph, index|
            mark_index = coverage_index(mark_coverage, glyph)
            if mark_index
              next unless previous_base
              next unless coverage_includes?(base_coverage, @current_glyphs[previous_base])

              mark = mark_records[mark_index]
              base_index = coverage_index(base_coverage, @current_glyphs[previous_base])
              base_anchor =
                read_anchor_records(base_array, mark_class_count)[base_index][mark[:class]]
              mark_anchor = mark_records[mark_index][:anchor]
              attach_mark(
                @current_positions[previous_base], @current_positions[index],
                base_anchor, mark_anchor, previous_base,
              )
            else
              previous_base = index if coverage_includes?(base_coverage, glyph)
            end
          end
        end

        def apply_mark_to_mark(base)
          return unless read_u16(base) == 1

          mark1_coverage = field_absolute(base, read_u16(base + 2))
          mark2_coverage = field_absolute(base, read_u16(base + 4))
          mark_class_count = read_u16(base + 6)
          mark1_array = field_absolute(base, read_u16(base + 8))
          mark2_array = field_absolute(base, read_u16(base + 10))
          mark_records = read_mark_records(mark1_array)
          mark2_records = read_anchor_records(mark2_array, mark_class_count)
          @current_glyphs.each_with_index do |glyph, index|
            mark1_index = coverage_index(mark1_coverage, glyph)
            if mark1_index
              previous_index = index - 1
              mark2_index =
                previous_index >= 0 ? coverage_index(mark2_coverage, @current_glyphs[previous_index]) : nil
              next unless mark2_index

              mark1 = mark_records[mark1_index]
              anchor1 = mark1[:anchor]
              anchor2 = mark2_records[mark2_index][mark1[:class]]
              attach_mark(
                @current_positions[previous_index], @current_positions[index],
                anchor2, anchor1, previous_index,
              )
            end
          end
        end

        def read_mark_records(base)
          count = read_u16(base)
          count.times.map do |index|
            record = base + 2 + (index * 4)
            class_value = read_u16(record)
            anchor_offset = read_u16(record + 2)
            anchor = anchor_offset.zero? ? nil : base + anchor_offset
            { class: class_value, anchor: read_anchor(anchor) }
          end
        end

        def read_anchor_records(base, class_count)
          count = read_u16(base)
          count.times.map do |glyph_index|
            record = base + 2 + (glyph_index * class_count * 2)
            class_count.times.map do |class_index|
              anchor_offset = read_u16(record + (class_index * 2))
              next nil if anchor_offset.zero?

              read_anchor(base + anchor_offset)
            end
          end
        end

        def attach_mark(base_position, mark_position, base_anchor, mark_anchor, index)
          mark_position.x_placement =
            base_position.x_placement + base_anchor[:x] - mark_anchor[:x]
          mark_position.y_placement =
            base_position.y_placement + base_anchor[:y] - mark_anchor[:y]
          mark_position.x_advance = 0
          mark_position.attached_to = index
        end

        def assign_origins(positions)
          pen_x = 0
          positions.each_with_index do |position, index|
            if position.attached_to
              base = positions[position.attached_to]
              position.x_origin = base.x_origin
            else
              position.x_origin = pen_x
            end
            pen_x += position.x_advance
          end
        end

        def read_anchor(base)
          { x: read_i16(base + 2), y: read_i16(base + 4) }
        end

        def each_pair_position
          (@current_glyphs.length - 1).times { |index| yield(index) }
        end

        def apply_value_record(value_format, base, position)
          cursor = base
          [
            [X_PLACEMENT, :x_placement, :i16],
            [Y_PLACEMENT, :y_placement, :i16],
            [X_ADVANCE, :x_advance, :i16],
            [Y_ADVANCE, nil, :i16],
            [X_PLACEMENT_DEVICE, nil, :device],
            [Y_PLACEMENT_DEVICE, nil, :device],
            [X_ADVANCE_DEVICE, nil, :device],
            [Y_ADVANCE_DEVICE, nil, :device],
          ].each do |flag, attribute, type|
            next unless (value_format & flag).positive?

            value = type == :i16 ? read_i16(cursor) : read_u16(cursor)
            position[attribute] += value if attribute && type != :device
            cursor += 2
          end
        end

        def value_record_size(value_format)
          size = 0
          [
            X_PLACEMENT, Y_PLACEMENT, X_ADVANCE, Y_ADVANCE,
            X_PLACEMENT_DEVICE, Y_PLACEMENT_DEVICE,
            X_ADVANCE_DEVICE, Y_ADVANCE_DEVICE,
          ].each { |flag| size += 2 if (value_format & flag).positive? }
          size
        end

        def coverage_index(base, glyph)
          return nil unless base

          format = read_u16(base)
          if format == 1
            count = read_u16(base + 2)
            count.times do |index|
              record = base + 4 + (index * 6)
              start_glyph = read_u16(record)
              end_glyph = read_u16(record + 2)
              index_offset = read_u16(record + 4)
              return index_offset + glyph - start_glyph if (start_glyph..end_glyph).cover?(glyph)
            end
          elsif format == 2
            count = read_u16(base + 2)
            count.times do |index|
              return index if read_u16(base + 4 + (index * 2)) == glyph
            end
          end
          nil
        end

        def coverage_includes?(base, glyph)
          !coverage_index(base, glyph).nil?
        end

        def class_membership(base, glyph, coverage = nil)
          coverage_result = coverage && coverage_index(coverage, glyph)
          return nil if coverage && coverage_result.nil?

          format = read_u16(base)
          klass =
            case format
            when 1
              read_u16(base + 2 + (glyph * 2))
            when 2
              ranges = read_class_range_records(base)
              range = ranges.find do |record|
                (record[:start]..record[:end]).cover?(glyph)
              end
              range ? range[:class] : 0
            else
              0
            end
          klass
        end

        def read_class_range_records(base)
          count = read_u16(base + 2)
          count.times.map do |index|
            record = base + 4 + (index * 6)
            {
              start: read_u16(record),
              end: read_u16(record + 2),
              class: read_u16(record + 4),
            }
          end
        end

        def field_absolute(base, offset)
          offset&.zero? ? nil : base + offset
        end

        def read_tag(offset)
          io_seek(offset)
          @ttf.contents.read(4)
        end

        def read_u16(offset)
          io_seek(offset)
          @ttf.contents.read(2).unpack1('n')
        end

        def read_i16(offset)
          io_seek(offset)
          @ttf.contents.read(2).unpack1('s>')
        end

        def read_u32(offset)
          io_seek(offset)
          @ttf.contents.read(4).unpack1('N')
        end

        def io_seek(offset)
          @ttf.contents.seek(offset)
        end

        def table_offset
          @info[:offset]
        end

        def header
          @header ||= {
            script_list: read_u16(table_offset + 4),
            feature_list: read_u16(table_offset + 6),
            lookup_list: read_u16(table_offset + 8),
          }
        end

        def script_list_offset
          table_offset + header[:script_list]
        end

        def feature_list_offset
          table_offset + header[:feature_list]
        end

        def lookup_list_offset
          table_offset + header[:lookup_list]
        end
      end
    end
  end
end
