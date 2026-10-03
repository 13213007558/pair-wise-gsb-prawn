# frozen_string_literal: true

require 'tempfile'

# Helpers for building fonts with vertical layout tables for specs.
module VerticalFontHelpers
  # Build a minimal GSUB table containing a single feature (vert or vrt2)
  # with a single SingleSubst lookup.
  #
  # @param feature_tag [String] "vert" or "vrt2"
  # @param substitution_format [Integer] SingleSubst format (1 or 2)
  # @param coverage_format [Integer] coverage format (1 or 2)
  # @param substitutions [Hash{Integer => Integer}] glyph ID mapping.
  #   For substitution format 1 the deltas must all be equal.
  # @return [String]
  def build_gsub_table(
    feature_tag: 'vert',
    substitution_format: 2,
    coverage_format: 1,
    substitutions: {}
  )
    src = substitutions.keys.sort

    coverage =
      case coverage_format
      when 1
        [1, src.length, *src].pack('n*')
      when 2
        ranges = []
        src.each do |glyph_id|
          if ranges.any? && ranges.last[1] == glyph_id - 1
            ranges.last[1] = glyph_id
          else
            ranges << [glyph_id, glyph_id]
          end
        end
        start_index = 0
        records = ranges.flat_map do |first, last|
          record = [first, last, start_index]
          start_index += last - first + 1
          record
        end
        [2, ranges.length, *records].pack('n*')
      else
        raise ArgumentError, "unsupported coverage format #{coverage_format}"
      end

    single =
      case substitution_format
      when 1
        deltas = src.map { |g| substitutions[g] - g }.uniq
        raise ArgumentError, 'ambiguous delta' if deltas.length != 1

        [1, 6, deltas.first & 0xFFFF].pack('n3') + coverage
      when 2
        dst = src.map { |g| substitutions[g] }
        [2, 6 + (dst.length * 2), dst.length, *dst].pack('n*') + coverage
      else
        raise ArgumentError,
          "unsupported substitution format #{substitution_format}"
      end

    lookup = [1, 0, 1, 8].pack('n*') + single
    lookup_list = [1, 4].pack('n*') + lookup
    feature = [0, 1, 0].pack('n*')
    feature_list = [1].pack('n') + feature_tag + [8].pack('n') + feature
    header = [1, 0, 10, 12, 12 + feature_list.bytesize].pack('n5')

    header + [0].pack('n') + feature_list + lookup_list
  end

  # Inject an additional table into a TrueType/OpenType font file.
  #
  # @param font_path [String] path to the original font
  # @param tag [String] table tag (4 bytes)
  # @param table_data [String] table contents
  # @return [String] new font file contents
  def inject_font_table(font_path, tag, table_data)
    data = File.binread(font_path)
    sfnt = data[0, 4]
    table_count = data[4, 2].unpack1('n')
    directory_length = 12 + (table_count * 16)

    offset = (data.bytesize + 3) & ~3
    table_data_offset = offset + 16

    entries = []
    table_count.times do |i|
      entry_tag, checksum, entry_offset, length =
        data[12 + (i * 16), 16].unpack('a4N3')
      entries << [entry_tag, checksum, entry_offset + 16, length].pack('a4N3')
    end
    entries << [tag, 0, table_data_offset, table_data.bytesize].pack('a4N3')
    entries.sort_by! { |entry| entry[0, 4] }

    body = data[directory_length..]
    body << "\0" * (offset - data.bytesize)
    body << table_data

    sfnt + [table_count + 1, 0, 0, 0].pack('n4') + entries.join + body
  end

  # Write a copy of the font with an additional table to a temporary
  # file and return its path.
  #
  # @param font_path [String] path to the original font
  # @param tag [String] table tag
  # @param table_data [String] table contents
  # @return [String] path to the new font file
  def font_with_extra_table(font_path, tag, table_data)
    file = Tempfile.create(%W[#{tag.strip} .ttf])
    file.binmode
    file.write(inject_font_table(font_path, tag, table_data))
    file.flush
    file.path
  end
end
