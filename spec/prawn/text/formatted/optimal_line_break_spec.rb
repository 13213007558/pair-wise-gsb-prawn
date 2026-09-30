# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Text::Formatted::OptimalLineBreak do
  let(:pdf) { create_pdf }

  def planner(width:, stretch:, shrink:, justify: true)
    described_class.new(
      pdf,
      width: width,
      kerning: false,
      stretch: stretch,
      shrink: shrink,
      justify: justify,
    )
  end

  def atoms(planner, text)
    source = { text: text, source_hash_id: text.object_id }
    planner.send(:atoms_for, [source])
  end

  def boundary_map(lines)
    lines.map { |line| [line.first, line.last, line.adjustment] }
  end

  it 'matches exhaustive line choices for a small justified paragraph' do
    pdf.font('Courier')
    text = 'aaaaaaaa bbbbbbbb cccccccc dddddddd eeeeeeee ffffffff'
    width = pdf.width_of('c' * 18)
    optimal = planner(width: width, stretch: 6, shrink: 3)
    token_atoms = atoms(optimal, text)
    optimal.send(:force_character_breaks, token_atoms)
    optimal.send(:prepare_line_measurements, token_atoms)

    exhaustive = planner(width: width, stretch: 6, shrink: 3)
    exhaustive_atoms = atoms(exhaustive, text)
    exhaustive.send(:force_character_breaks, exhaustive_atoms)

    optimal.layout([{ text: text }])

    expect(boundary_map(optimal.lines))
      .to eq(boundary_map(exhaustive.send(:exhaustive_lines, exhaustive_atoms)))
  end

  it 'penalizes consecutive hard-hyphenated lines' do
    pdf.font('Courier')
    text = 'aa-aa bb-bb cc-cc dd-dd ee-ee'
    width = pdf.width_of('d' * 3) + 1

    optimal = planner(width: width, stretch: 100, shrink: 1)
    optimal.layout([{ text: text }])

    expect(optimal.lines.map(&:hyphenated).each_cons(2))
      .to_not include([true, true])
    expect(optimal.lines.map(&:hyphenated)).to include(true)
  end

  it 'uses optional soft hyphens only at selected breaks' do
    pdf.font("#{Prawn::DATADIR}/fonts/DejaVuSans.ttf")
    text = "hypo#{Prawn::Text::SHY}ther#{Prawn::Text::SHY}mis"
    optimal = described_class.new(
      pdf,
      width: pdf.width_of('thermis') + 1,
      kerning: false,
      stretch: 1_000,
      shrink: 100,
      justify: true,
    )

    optimal.layout([{ text: text }])

    expect(optimal.lines.map { |line| line.fragments.map { |f| f[:text] } })
      .to eq([["hypo#{Prawn::Text::SHY}"], ["thermis"]])
  end

  it 'does not justify the final line' do
    text = 'one two three four'
    width = pdf.width_of('one two three') + 1
    optimal = planner(width: width, stretch: 10, shrink: 5)

    optimal.layout([{ text: text }])

    expect(optimal.lines.last.adjustment).to eq(0)
    expect(optimal.lines.last.width).to be <= width
  end

  it 'measures changes in font size and font style per fragment' do
    text = [
      { text: 'small ', size: 8 },
      { text: 'large', size: 24, styles: [:bold] },
      { text: ' normal' },
    ]
    optimal = planner(width: 1000, stretch: 10, shrink: 5)

    optimal.layout(text)

    expect(optimal.lines.first.fragments.map { |fragment|
      [fragment[:text], fragment[:size], fragment[:styles]]
    }).to eq([
      ['small ', 8, nil],
      ['large', 24, [:bold]],
      [' normal', nil, nil],
    ])
  end

  it 'splits an unbreakable word once by character instead of retrying' do
    optimal = planner(width: 10, stretch: 10, shrink: 5)

    expect {
      optimal.layout([{ text: 'unbreakable' }])
    }.to_not raise_error

    expect(optimal.lines.length).to be > 1
    expect(optimal.work_units).to be > 0
  end

  it 'raises CannotFit when character breaks are disabled and a word is too wide' do
    optimal = described_class.new(
      pdf,
      width: 1,
      kerning: false,
      stretch: 10,
      shrink: 5,
      justify: true,
      disable_wrap_by_char: true,
    )

    expect {
      optimal.layout([{ text: 'unbreakable' }])
    }.to raise_error(Prawn::Errors::CannotFit)
  end

  it 'keeps long-paragraph work proportional to the square of break candidates' do
    small = (1..20).map { |number| "word#{number}" }.join(' ')
    large = (1..80).map { |number| "word#{number}" }.join(' ')

    small_planner = planner(width: 200, stretch: 100, shrink: 100)
    large_planner = planner(width: 200, stretch: 100, shrink: 100)
    small_planner.layout([{ text: small }])
    large_planner.layout([{ text: large }])

    ratio = large_planner.work_units.to_f / small_planner.work_units
    candidate_ratio = 4.0

    expect(ratio).to be < candidate_ratio**2 * 1.5
  end
end
