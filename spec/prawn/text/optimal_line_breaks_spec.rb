# frozen_string_literal: true

require 'spec_helper'

describe 'optimal line breaks' do
  let(:pdf) { create_pdf }

  it 'uses optimal breaks for text boxes' do
    pdf.font('Courier')
    box = Prawn::Text::Box.new(
      'a bbbbb cc ddd eeeee',
      document: pdf,
      width: 51,
      line_breaks: :optimal,
    )
    box.render

    expect(box.text).to eq("a bbbbb\ncc ddd\neeeee")
  end

  it 'keeps paragraph boundaries' do
    box = Prawn::Text::Box.new(
      "aa bbb\ncc",
      document: pdf,
      width: 30,
      line_breaks: :optimal,
    )
    box.render

    expect(box.text).to eq("aa\nbbb\ncc")
  end

  it 'uses planned word spacing for justified lines only' do
    pdf.font('Courier')
    box = Prawn::Text::Box.new(
      'a bbbbb cc ddd eeeee',
      document: pdf,
      width: 51,
      align: :justify,
      line_breaks: :optimal,
    )
    box.render
    contents = PDF::Inspector::Text.analyze(pdf.render)

    expect(contents.word_spacing).to include(a_value_within(1e-9).of(0.6))
    expect(contents.word_spacing.last).to eq(0)
  end

  it 'respects a maximum word spacing bound' do
    pdf.font('Courier')
    box = Prawn::Text::Box.new(
      'a bbbbb cc ddd eeeee',
      document: pdf,
      width: 51,
      align: :justify,
      line_breaks: :optimal,
      word_spacing: { max: 0.3 },
    )
    box.render
    contents = PDF::Inspector::Text.analyze(pdf.render)

    expect(contents.word_spacing).to include(
      a_value_within(1e-9).of(0.3),
    )
  end

  it 'raises for an unknown line breaking mode' do
    expect {
      Prawn::Text::Box.new(
        'abc',
        document: pdf,
        line_breaks: :fast,
      )
    }.to raise_error(
      ArgumentError,
      'line_breaks must be one of :greedy or :optimal symbols',
    )
  end

  it 'raises for an unsupported word spacing value' do
    expect {
      Prawn::Text::Box.new(
        'abc',
        document: pdf,
        word_spacing: 2,
      )
    }.to raise_error(
      ArgumentError,
      'word_spacing must be a Hash or Range',
    )
  end
end
