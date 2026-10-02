# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Text::Formatted::OptimalLineWrap do
  let(:pdf) { create_pdf }

  def planner(text, **options)
    described_class.new(text, {
      document: pdf,
      kerning: false,
      character_spacing: 0,
    }.merge(options))
  end

  it 'chooses a lower-cost global break instead of the greedy break' do
    pdf.font('Courier')
    text = [{ text: 'a bbbbb cc ddd eeeee' }]
    optimal = planner(text, width: 51)
    optimal.wrap

    rendered_lines = optimal.lines.map do |line|
      line.reject { |hash| hash[:text] == "\n" }
        .map { |hash| hash[:text] }.join
    end
    expect(rendered_lines).to eq(['a bbbbb', 'cc ddd', 'eeeee'])

    greedy = [[0, 0], [2, 2], [4, 6], [8, 8]]
    expect(optimal.breaks).not_to eq(greedy)
  end

  it 'matches the minimum cost after enumerating every legal break subset' do
    pdf.font('Courier')
    words = %w[a bbbbb cc ddd eeeee]
    width = 51
    space = pdf.width_of(' ')
    word_widths = words.map { |word| pdf.width_of(word) }
    optimal = planner(
      [{ text: words.join(' ') }],
      width: width,
      kerning: false,
    )
    optimal.wrap

    costs = []
    (0...(1 << (words.length - 1))).each do |mask_bits|
      cuts = words.each_index.filter do |index|
        index.nonzero? && (mask_bits & (1 << (index - 1))).nonzero?
      end
      boundaries = [0, *cuts.map { |cut| cut + 1 }, words.length]
      feasible = boundaries.each_cons(2).all? do |start, finish|
        word_widths[start...finish].sum +
          (space * (finish - start - 1)) <= width + 1e-9
      end
      next unless feasible

      cost = 0
      boundaries.each_cons(2).with_index do |(start, finish), index|
        slack = width - word_widths[start...finish].sum -
          (space * (finish - start - 1))
        badness = (slack.abs / width.to_f)**2
        if index == boundaries.length - 2
          badness *= described_class::LAST_LINE_FACTOR
        end
        cost += badness
      end
      costs << cost
    end

    expect(costs.min).to be_within(1e-12).of(optimal.cost)
  end

  it 'measures fragments in their own font, size, and style' do
    pdf.font('Courier')
    text = [
      { text: 'hello', styles: [:bold] },
      { text: ' world', size: 24 },
    ]
    optimal = planner(text, width: 70)
    optimal.wrap

    lines = optimal.lines.map do |line|
      line.reject { |hash| hash[:text] == "\n" }
        .map { |hash| hash[:text] }.join
    end
    expect(lines).to eq(['hello w', 'orld'])
  end

  it 'removes unselected soft hyphens and keeps the selected one' do
    pdf.font("#{Prawn::DATADIR}/fonts/DejaVuSans.ttf")
    full = planner([{ text: "hy\u00ADphen\u00ADa\u00ADtion" }], width: 200)
    full.wrap
    expect(full.lines.first.first[:text]).to eq('hyphenation')

    text = [
      { text: 'hyphena' },
      { text: "\u00ADtion" },
      { text: ' word' },
    ]
    broken = planner(text, width: 60)
    broken.wrap

    expect(broken.lines.first.first[:text]).to end_with(Prawn::Text::SHY)
    final_line = broken.lines.last.reject { |hash| hash[:text] == "\n" }
    expect(final_line.map { |hash| hash[:text] }.join).to eq('tion word')
  end

  it 'penalizes consecutive hyphenated line endings' do
    optimal = planner([{ text: 'short' }], width: 100)
    atoms = optimal.send(:build_atoms)
    prefixes = optimal.send(:prefix_widths, atoms)
    candidate = {
      start: 0,
      finish: atoms.length - 1,
      next_start: atoms.length,
      kind: :hyphen,
      hyphen: true,
    }

    normal, = optimal.send(
      :line_cost,
      candidate.merge(previous_hyphen: false),
      atoms,
      prefixes,
      false,
    )
    consecutive, = optimal.send(
      :line_cost,
      candidate.merge(previous_hyphen: true),
      atoms,
      prefixes,
      false,
    )

    expect(consecutive - normal)
      .to be_within(1e-12)
      .of(described_class::CONSECUTIVE_HYPHEN_PENALTY)
  end

  it 'avoids consecutive hyphen breaks when another layout is cheaper' do
    pdf.font('Courier')
    optimal = planner(
      [{ text: 'x-y-z foo bar' }],
      width: 36,
    )
    optimal.wrap

    lines = optimal.lines.map do |line|
      line.reject { |hash| hash[:text] == "\n" }
        .map { |hash| hash[:text] }.join
    end
    expect(lines).to eq(['x-y-', 'z foo', 'bar'])
  end

  it 'splits an overlong non-breakable word by character' do
    optimal = planner([{ text: 'supercalifragilistic' }], width: 30)
    optimal.wrap

    lines = optimal.lines.map do |line|
      line.reject { |hash| hash[:text] == "\n" }
        .map { |hash| hash[:text] }.join
    end
    expect(lines).to eq(%w[supe rcali frag ilistic])
  end

  it 'raises CannotFit for an overlong word when character breaks are disabled' do
    optimal = planner(
      [{ text: 'supercalifragilistic' }],
      width: 30,
      disable_wrap_by_char: true,
    )

    expect { optimal.wrap }.to raise_error(Prawn::Errors::CannotFit)
  end

  it 'does not stretch the final line when justifying' do
    pdf.font('Courier')
    optimal = planner(
      [{ text: 'aaa bbb' }],
      width: 100,
      justify: true,
    )
    optimal.wrap

    expect(optimal.word_spacings).to eq([0])
  end
end
