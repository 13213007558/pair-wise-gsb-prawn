# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Fonts::GSUB do
  it 'is not available for fonts without a GSUB table' do
    ttf = TTFunk::File.open("#{Prawn::DATADIR}/fonts/gkai00mp.ttf")
    expect(described_class.for(ttf)).to be_nil
  end

  it 'resolves single substitutions in explicit form' do
    gsub = described_class.new(
      build_gsub_table(
        substitution_format: 2,
        substitutions: { 417 => 721, 418 => 722, 421 => 713 },
      ),
    )

    expect(gsub.substitute(417)).to eq(721)
    expect(gsub.substitute(418)).to eq(722)
    expect(gsub.substitute(421)).to eq(713)
    expect(gsub.substitute(980)).to be_nil
  end

  it 'resolves single substitutions in delta form' do
    gsub = described_class.new(
      build_gsub_table(
        substitution_format: 1,
        substitutions: { 417 => 721, 418 => 722 },
      ),
    )

    expect(gsub.substitute(417)).to eq(721)
    expect(gsub.substitute(418)).to eq(722)
    expect(gsub.substitute(421)).to be_nil
  end

  it 'resolves substitutions with range coverage' do
    gsub = described_class.new(
      build_gsub_table(
        substitution_format: 2,
        coverage_format: 2,
        substitutions: { 417 => 721, 418 => 722, 421 => 713 },
      ),
    )

    expect(gsub.substitute(417)).to eq(721)
    expect(gsub.substitute(418)).to eq(722)
    expect(gsub.substitute(421)).to eq(713)
    expect(gsub.substitute(419)).to be_nil
  end

  it 'prefers vrt2 over vert' do
    vert = build_gsub_table(
      feature_tag: 'vert',
      substitutions: { 417 => 721 },
    )
    vrt2 = build_gsub_table(
      feature_tag: 'vrt2',
      substitutions: { 417 => 700 },
    )

    # merge the two tables: one GSUB with both features
    gsub = described_class.new(build_gsub_with_features(vert, vrt2))
    expect(gsub.substitute(417)).to eq(700)
  end

  it 'ignores non-vertical features' do
    gsub = described_class.new(
      build_gsub_table(
        feature_tag: 'liga',
        substitutions: { 417 => 721 },
      ),
    )

    expect(gsub.substitute(417)).to be_nil
  end

  it 'ignores non-single-substitution lookups' do
    data = build_gsub_table(substitutions: { 417 => 721 })
    # change the lookup type to 4 (LigatureSubst)
    lookup_list_offset = data[8, 2].unpack1('n')
    lookup_offset =
      lookup_list_offset + data[lookup_list_offset + 2, 2].unpack1('n')
    data = data.dup
    data[lookup_offset, 2] = [4].pack('n')

    gsub = described_class.new(data)
    expect(gsub.substitute(417)).to be_nil
  end

  # Combine the feature lists of several GSUB tables into one table.
  def build_gsub_with_features(*tables)
    features = []
    lookups = []

    tables.each do |table|
      feature_list_offset = table[6, 2].unpack1('n')
      lookup_list_offset = table[8, 2].unpack1('n')

      feature_count = table[feature_list_offset, 2].unpack1('n')
      feature_count.times do |i|
        record = feature_list_offset + 2 + (i * 6)
        tag = table[record, 4]
        feature_offset =
          feature_list_offset + table[record + 4, 2].unpack1('n')
        lookup_count = table[feature_offset + 2, 2].unpack1('n')
        lookup_count.times do |j|
          lookup_index = table[feature_offset + 4 + (j * 2), 2].unpack1('n')
          lookup_offset =
            lookup_list_offset +
            table[lookup_list_offset + 2 + (lookup_index * 2), 2].unpack1('n')
          lookup_length =
            j + 1 < lookup_count ? 0 : table.bytesize - lookup_offset
          features << [tag, lookups.length]
          lookups << table[lookup_offset, lookup_length]
        end
      end
    end

    header_length = 12
    feature_list = [features.length].pack('n')
    feature_data = +''
    features.each do |tag, lookup_index|
      feature_list <<
        tag <<
        [2 + (features.length * 6) + feature_data.bytesize].pack('n')
      feature_data << [0, 1, lookup_index].pack('n*')
    end
    feature_list << feature_data

    lookup_list = [lookups.length].pack('n')
    lookup_data = +''
    lookups.each do |lookup|
      lookup_list << [2 + (lookups.length * 2) + lookup_data.bytesize].pack('n')
      lookup_data << lookup
    end
    lookup_list << lookup_data

    [1, 0, 10, header_length, header_length + feature_list.bytesize]
      .pack('n5') + [0].pack('n') + feature_list + lookup_list
  end
end
