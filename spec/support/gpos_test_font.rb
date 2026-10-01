# frozen_string_literal: true

require 'ttfunk'
require 'tempfile'

module GposTestFont
  SOURCE_PATH = File.expand_path('../../data/fonts/DejaVuSans.ttf', __dir__)
  FONT_NAME = 'DejaVuSansGpos.ttf'

  def self.path
    @path ||= Tempfile.new([FONT_NAME.delete_suffix('.ttf'), '.ttf']).tap do |file|
      file.binmode
      file.write(font_with_gpos)
      file.flush
    end
    @path.path
  end

  def self.font_with_gpos
    original = File.binread(SOURCE_PATH)
    replace_table(original, 'GPOS', gpos_table(original))
  end

  def self.replace_table(original, tag, table)
    scaler = original.unpack1('N')
    entries = table_entries(original).merge(
      tag => { checksum: checksum(table), data: table },
    )
    tags = entries.keys.sort
    power_of_two = 2**Integer(Math.log2(tags.length))

    header = [
      scaler, tags.length, power_of_two * 16,
      Integer(Math.log2(power_of_two)), tags.length * 16 - power_of_two * 16,
    ].pack('Nn4')

    records = +''.b
    data = +''.b
    offset = header.length + tags.length * 16

    tags.each do |entry_tag|
      chunk = entries[entry_tag][:data]
      records << [
        entry_tag, entries[entry_tag][:checksum], offset, chunk.length,
      ].pack('a4N3')
      data << chunk
      padding = (4 - chunk.length) % 4
      data << "\0" * padding
      offset += chunk.length + padding
    end

    header + records + data
  end

  def self.table_entries(original)
    count = original.unpack1('x4n')
    count.times.each_with_object({}) do |index, entries|
      tag, checksum, offset, length = original.byteslice(12 + index * 16, 16).unpack('a4N3')
      entries[tag] = { checksum: checksum, data: original.byteslice(offset, length) }
    end
  end

  def self.checksum(data)
    padded = data.b + ("\0" * ((4 - data.bytesize) % 4))
    padded.unpack('N*').sum & 0xFFFF_FFFF
  end

  def self.gpos_table(original)
    font = TTFunk::File.new(original)
    cmap = font.cmap.unicode.first.code_map
    glyphs = {
      T: cmap[84], o: cmap[111], a: cmap[97], x: cmap[120],
      acute: cmap[769], dot: cmap[803],
    }
    GposBuilder.new(glyphs).build
  end

  class GposBuilder
    def initialize(glyphs)
      @g = glyphs
    end

    def build
      lookup0 = pair_pos_lookup
      lookup1 = mark_to_base_lookup
      lookup2 = mark_to_mark_lookup

      script_list = build_script_list
      feature_list = build_feature_list
      lookup_list = build_lookup_list([lookup0, lookup1, lookup2])

      [0x00010000, 10, 10 + script_list.length,
       10 + script_list.length + feature_list.length].pack('Nn3') +
        script_list + feature_list + lookup_list
    end

    private

    def build_script_list
      langsys = [0, 0, 0xFFFF, 3, 0, 1, 2].pack('n7')
      script = [4, 0].pack('n2') + langsys
      [1].pack('n') + ['DFLT'].pack('a4') + [10].pack('N') + script
    end

    def build_feature_list
      records = +''.b
      tables = +''.b
      [%w[kern 0], %w[mark 1], %w[mkmk 2]].each do |tag, lookup|
        tables << [0, 1, lookup.to_i].pack('n3')
      end
      [%w[kern 0], %w[mark 1], %w[mkmk 2]].each_with_index do |(tag, _lookup), index|
        records << [tag.ljust(4, ' '), 20 + index * 6].pack('a4n')
      end
      [3].pack('n') + records + tables
    end

    def build_lookup_list(lookups)
      offsets = +''.b
      data = +''.b
      lookups.each do |lookup|
        offsets << [8 + data.length].pack('n')
        data << lookup
      end
      [lookups.length].pack('n') + offsets + data
    end

    def lookup(type, subtable)
      [type, 0, 1, 8].pack('n4') + subtable
    end

    def pair_pos_lookup
      coverage1 = coverage([@g[:T], @g[:a], @g[:o], @g[:x]])
      coverage2 = coverage([@g[:o], @g[:x]])
      class1 = class_def(
        @g[:T] => 1, @g[:a] => 1, @g[:o] => 2, @g[:x] => 2,
      )
      class2 = class_def(@g[:o] => 1, @g[:x] => 2)
      header = [
        2, 20, 20 + coverage1.length, 20 + coverage1.length + coverage2.length,
        0x0004, 0, 2, 2, 0, 0,
      ].pack('n10')
      records = [-40, 0, 0, 60].pack('s>4')
      lookup(
        2,
        header + coverage1 + coverage2 + class1 + class2 + records,
      )
    end

    def mark_to_base_lookup
      mark_anchor = anchor(10, 20)
      base_anchor = anchor(500, 700)
      mark_array = [1, 0, 6].pack('n3') + mark_anchor
      base_array = [1, 4].pack('n2') + base_anchor
      subtable = positioning_subtable(
        coverage([@g[:acute]]), coverage([@g[:a]]), mark_array, base_array,
      )
      lookup(4, subtable)
    end

    def mark_to_mark_lookup
      mark_anchor = anchor(20, 30)
      base_mark_anchor = anchor(700, 200)
      mark_array = [1, 0, 6].pack('n3') + mark_anchor
      base_array = [1, 4].pack('n2') + base_mark_anchor
      subtable = positioning_subtable(
        coverage([@g[:dot]]), coverage([@g[:acute]]), mark_array, base_array,
      )
      lookup(6, subtable)
    end

    def positioning_subtable(mark_coverage, base_coverage, mark_array, base_array)
      offset = 12
      mark_coverage_offset = offset
      offset += mark_coverage.length
      base_coverage_offset = offset
      offset += base_coverage.length
      mark_array_offset = offset
      offset += mark_array.length
      base_array_offset = offset
      header = [1, mark_coverage_offset, base_coverage_offset, 1,
                mark_array_offset, base_array_offset].pack('n6')
      header + mark_coverage + base_coverage + mark_array + base_array
    end

      def coverage(glyphs)
      glyphs = glyphs.sort
      [2, glyphs.length, *glyphs].pack('n*')
    end

    def class_def(classes)
      records = classes.sort_by { |glyph, _| glyph }
      [2, records.length].pack('n2') +
        records.map { |glyph, klass| [glyph, glyph, klass].pack('n3') }.join
    end

    def anchor(x, y)
      [1].pack('n') + [x, y].pack('s>2')
    end
  end
end
