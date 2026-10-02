# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Text::Bidi do
  it 'uses Unicode 15.1.0 conformance data' do
    expect(described_class::UNICODE_VERSION).to eq('15.1.0')
  end

  it 'passes the bundled public BidiCharacterTest vectors' do
    path = File.expand_path('../../data/bidi_character_test_15.1.0.txt', __dir__)

    File.readlines(path).each do |line|
      next if line.start_with?('#') || line.strip.empty?

      input, direction, paragraph_level, levels, ordering =
        line.split(';').map(&:strip)
      text = input.split.map { |codepoint|
        codepoint.to_i(16).chr(::Encoding::UTF_8)
      }.join
      direction_argument = { '0' => :ltr, '1' => :rtl, '2' => nil }.fetch(direction)
      bidi = described_class.new(text, direction_argument)

      expect(bidi.paragraph_level).to eq(paragraph_level.to_i)
      expect(bidi.visual_positions.map(&:index)).to eq(ordering.split.map(&:to_i))

      resolved_levels = levels.delete_prefix('[').delete_suffix(']').split
      resolved_levels.each_with_index do |level, index|
        next if level == 'x'

        expect(bidi.visual_positions).to include(
          an_object_having_attributes(index: index, level: level.to_i),
        )
      end
    end
  end

  it 'retains logical indices while exposing mirrored visual characters' do
    positions = described_class.visual_positions('(123)', direction: :rtl)

    expect(positions.map(&:char)).to eq(%w[) 1 2 3 (])
    expect(positions.map(&:index)).to eq([4, 1, 2, 3, 0])
    expect(positions.select(&:mirror).map(&:char)).to eq(%w[) (])
  end

  it 'removes explicit bidi controls from visual output' do
    text = "\u2067abc\u2069"

    expect(described_class.visible_text(text, direction: :rtl)).to eq('abc')
  end
end
