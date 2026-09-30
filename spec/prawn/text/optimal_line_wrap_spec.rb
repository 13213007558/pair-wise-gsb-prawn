# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Text::Formatted::OptimalLineWrap do
  let(:pdf) { create_pdf }

  def render_box(text, **options)
    font = options.delete(:font)
    pdf.font(font) if font
    Prawn::Text::Box.new(
      text,
      {
        document: pdf,
        width: 60,
        overflow: :expand,
      }.merge(options) do |_key, default, custom|
        custom.nil? ? default : custom
      end,
    ).tap(&:render)
  end

  it 'keeps greedy wrapping as the default' do
    text = 'one two three four five six seven eight nine ten eleven twelve'
    greedy_box = render_box(text, font: 'Courier')
    optimal_box = render_box(
      text,
      font: 'Courier',
      align: :justify,
      optimal_wrapping: true,
    )
    expect(greedy_box.text.lines.map(&:chomp)).to eq(
      ['one two', 'three', 'four', 'five six', 'seven', 'eight', 'nine ten', 'eleven', 'twelve'],
    )
    expect(greedy_box.line_breaks.map { |line| line[:text] })
      .to eq(greedy_box.text.lines.map(&:chomp))
    expect(greedy_box.line_breaks.map { |line| line[:adjustment] })
      .to all(eq(0))
    expect(greedy_box.line_adjustments).to all(eq(0))
    expect(optimal_box.text.lines.map(&:chomp)).to eq(
      ['one two', 'three', 'four five', 'six seven', 'eight', 'nine ten', 'eleven', 'twelve'],
    )
  end

  it 'uses paragraph-wide breaks and per-line inter-word adjustments' do
    text = 'one two three four five six seven eight nine ten eleven twelve'
    box = render_box(
      text,
      font: 'Courier',
      align: :justify,
      optimal_wrapping: true,
    )

    expect(box.text.lines.map(&:chomp)).to eq(
      ['one two', 'three', 'four five', 'six seven', 'eight', 'nine ten', 'eleven', 'twelve'],
    )
    expect(box.line_breaks.map { |line| line[:text] }).to eq(
      box.text.lines.map(&:chomp),
    )
    expected_adjustments = [4.8, 7.2, -2.4, -2.4, 7.2, 1.2, 7.2, 0.0]
    box.line_breaks.each_with_index do |line, index|
      expect(line[:adjustment]).to be_within(1e-9)
        .of(expected_adjustments[index])
    end
  end

  it 'accepts explicit stretch and shrink limits' do
    text = 'one two three four five six seven eight nine ten eleven twelve'
    box = render_box(
      text,
      font: 'Courier',
      align: :justify,
      optimal_wrapping: true,
      word_spacing_stretch: 7.2,
      word_spacing_shrink: 0,
    )

    expect(box.line_adjustments[0...-1]).to all(be >= 0)
    expect(box.line_adjustments).to all(be <= 7.2 + 1e-9)
  end

  it 'enables optimal wrapping through :line_wrapping' do
    text = 'one two three four five six seven eight nine ten eleven twelve'
    box = render_box(
      text,
      font: 'Courier',
      align: :justify,
      line_wrapping: :optimal,
    )

    expect(box.text).to include("four five\n")
  end

  it 'measures font, size and character spacing per fragment' do
    fragments = [
      { text: 'small normal words ' },
      { text: 'BIG', styles: [:bold], size: 18 },
      { text: ' trailing words here', character_spacing: 1 },
    ]
    box = Prawn::Text::Formatted::Box.new(
      fragments,
      document: pdf,
      width: 130,
      align: :justify,
      optimal_wrapping: true,
      overflow: :expand,
    )
    box.render

    expect(box.text).to include('BIG')
    expect(box.line_adjustments.length).to eq(box.text.lines.length)
  end

  it 'draws the planned adjustment as PDF word spacing' do
    box = render_box(
      'one two three four five six seven eight',
      font: 'Courier',
      align: :justify,
      optimal_wrapping: true,
    )
    contents = PDF::Inspector::Text.analyze(pdf.render)

    expect(contents.word_spacing).not_to be_empty
    expected = box.line_adjustments.uniq.sort
    actual = contents.word_spacing.uniq.sort
    expect(actual.length).to eq(expected.length)
    actual.each_with_index do |value, index|
      expect(value).to be_within(0.0001).of(expected[index])
    end
  end

  it 'breaks once on a long word without retrying indefinitely' do
    box = render_box(
      'You_can_wrap_this_text_HERE',
      font: 'Courier',
      width: 180,
      optimal_wrapping: true,
    )

    expect(box.text).to eq("You_can_wrap_this_text_HE\nRE")
  end

  it 'raises CannotFit when character breaks are disabled for a long word' do
    expect do
      render_box(
        'You_cannot_wrap_this_text_at_all_because_it_has_no_word_breaks',
        font: 'Courier',
        width: 180,
        optimal_wrapping: true,
        disable_wrap_by_char: true,
      )
    end.to raise_error(Prawn::Errors::CannotFit)
  end

  it 'uses optional hyphen breakpoints and leaves the final line unjustified' do
    pdf.font("#{Prawn::DATADIR}/fonts/DejaVuSans.ttf")
    text = "hyphen#{Prawn::Text::SHY}ation " * 4
    box = render_box(
      text,
      width: 60,
      align: :justify,
      optimal_wrapping: true,
    )

    expect(box.text).to include("hyphen#{Prawn::Text::SHY}\n")
    expect(box.line_adjustments.last).to eq(0)
  end

  it 'returns explicit paragraph breaks in line breaks' do
    box = render_box(
      "\nhello\n\nnext",
      width: 500,
      optimal_wrapping: true,
    )

    expect(box.text).to eq("\nhello\n\nnext")
    expect(box.line_breaks.map { |line| line[:text] }).to eq(
      ['', 'hello', '', 'next'],
    )
  end
end
