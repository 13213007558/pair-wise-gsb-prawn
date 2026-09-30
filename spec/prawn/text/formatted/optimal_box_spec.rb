# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Text::Formatted::Box do
  let(:pdf) { create_pdf }

  it 'keeps greedy line wrapping by default' do
    greedy = described_class.new(
      [{ text: 'one two three' }],
      document: pdf,
      width: pdf.width_of('one two') + 1,
      align: :justify,
    )
    greedy.render(dry_run: true)

    expect(greedy.line_adjustments).to eq([])
  end

  it 'does not affect unaligned wrapping when optimal breaks are requested' do
    box = described_class.new(
      [{ text: 'one two three' }],
      document: pdf,
      width: pdf.width_of('one two') + 1,
      line_break_strategy: :optimal,
    )
    box.render(dry_run: true)

    expect(box.line_adjustments).to all(eq(0.0))
  end

  it 'does not return the planned newline preceding unprinted text' do
    box = described_class.new(
      [{ text: 'word ' * 60 }],
      document: pdf,
      width: 80,
      height: pdf.font.height * 2 + 1,
      align: :justify,
      line_break_strategy: :optimal,
    )

    remaining = box.render

    expect(box.line_adjustments.length).to eq(2)
    expect(remaining).to_not start_with("\n")
  end

  it 'returns optimal line divisions and per-line adjustments' do
    box = described_class.new(
      [{ text: 'one two three four' }],
      document: pdf,
      width: pdf.width_of('one two three') + 1,
      align: :justify,
      line_break_strategy: :optimal,
    )
    box.render(dry_run: true)

    expect(box.text).to eq("one two three\nfour")
    expect(box.line_adjustments.length).to eq(2)
    expect(box.line_adjustments.first).to be > 0
    expect(box.line_adjustments.last).to eq(0)
  end

  it 'applies planned word spacing in the PDF content' do
    box = described_class.new(
      [{ text: 'one two three four' }],
      document: pdf,
      width: pdf.width_of('one two three') + 1,
      align: :justify,
      line_break_strategy: :optimal,
    )
    box.render
    contents = PDF::Inspector::Text.analyze(pdf.render)

    expect(contents.word_spacing).to include(a_value_within(0.0001)
      .of(box.line_adjustments.first))
  end

  it 'validates the line breaking strategy' do
    expect {
      described_class.new(
        [{ text: 'one two' }],
        document: pdf,
        line_break_strategy: :balanced,
      )
    }.to raise_error(
      ArgumentError,
      'line_break_strategy must be either :greedy or :optimal',
    )
  end
end
