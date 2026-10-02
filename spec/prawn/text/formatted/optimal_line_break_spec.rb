# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Text::Formatted::OptimalLineBreak do
  let(:pdf) { create_pdf }

  def paragraph_for(input, **options)
    arranger = Prawn::Text::Formatted::Arranger.new(
      pdf,
      kerning: options.fetch(:kerning, true),
    )
    fragments =
      if input.is_a?(Array)
        input
      else
        [{ text: input, font: 'Courier' }]
      end
    arranger.format_array = fragments

    described_class.new(
      pdf,
      arranger,
      kerning: true,
      width: options.fetch(:width),
      justify: options.fetch(:justify, true),
      disable_wrap_by_char: options.fetch(:disable_wrap_by_char, false),
      hyphen_penalty: options[:hyphen_penalty],
      consecutive_hyphen_penalty:
        options[:consecutive_hyphen_penalty],
    ).paragraph
  end

  def line_text(paragraph, index)
    paragraph.lines[index].fragments.map { |fragment|
      fragment[:text]
    }.join
  end

  def justified_badness(width, natural_width, space_count)
    return (width - natural_width).to_f ** 2 if space_count.zero?

    ((width - natural_width).to_f / space_count) ** 2
  end

  it 'chooses a global layout different from the greedy layout' do
    greedy_box = Prawn::Text::Formatted::Box.new(
      [{ text: 'aa b c ccc', font: 'Courier' }],
      document: pdf,
      width: 28.8,
      align: :justify,
      line_break: :greedy,
    )
    optimal_box = Prawn::Text::Formatted::Box.new(
      [{ text: 'aa b c ccc', font: 'Courier' }],
      document: pdf,
      width: 28.8,
      align: :justify,
      line_break: :optimal,
    )

    greedy_box.render
    optimal_box.render

    expect(greedy_box.text).to eq("aa b\nc\nccc")
    expect(optimal_box.text).to eq("aa\nb c\nccc")
  end

  it 'selects the minimum cost after enumerating every small breakpoint set' do
    width = 28.8
    words = %w[aa b c ccc]
    paragraph = paragraph_for(words.join(' '), width: width)

    candidates = [1, 2].repeated_permutation(3).map { |breaks|
      positions = breaks.filter_map.with_index(1) { |selected, index|
        index if selected == 1
      }
      line_ranges = [0, *positions, words.length].each_cons(2)
      line_ranges.map { |start, finish| words[start...finish].join(' ') }
    }

    costs = candidates.to_h { |lines|
      cost = lines.each_with_index.sum do |line, index|
        natural_width = begin
          measured_width = nil
          pdf.font('Courier') { measured_width = pdf.width_of(line) }
          measured_width
        end
        next Float::INFINITY if natural_width > width
        next 0 if index == lines.length - 1

        justified_badness(width, natural_width, line.count(' '))
      end
      [lines, cost]
    }

    selected = paragraph.lines.map { |line|
      line.fragments.map { |fragment| fragment[:text] }.join
    }
    expected_cost = costs.fetch(selected)

    expect(selected).to eq(['aa', 'b c', 'ccc'])
    expect(paragraph.cost).to eq(expected_cost)
    expect(paragraph.cost).to eq(costs.values.min)
    expect(expected_cost).to be < costs.fetch(['aa b', 'c', 'ccc'])
  end

  it 'does not justify the final line' do
    paragraph = paragraph_for('aa b ccc', width: 80)
    final_line = paragraph.lines.last

    expect(final_line.paragraph_finished).to be(true)
    expect(final_line.fragments.map { |fragment| fragment[:text] }.join)
      .to eq('aa b ccc')
    expect(paragraph.lines.length).to eq(1)
  end

  it 'breaks an overlong unbreakable word by character by default' do
    pdf.font('Courier')
    box = Prawn::Text::Formatted::Box.new(
      [{ text: 'abcdefgh' }],
      document: pdf,
      width: 14.4,
      height: 100,
      line_break: :optimal,
    )

    box.render
    expect(box.text).to eq("ab\ncd\nef\ngh")
  end

  it 'raises CannotFit for an overlong word when character breaks are disabled' do
    pdf.font('Courier')
    box = Prawn::Text::Formatted::Box.new(
      [{ text: 'abcdefgh' }],
      document: pdf,
      width: 21.6,
      line_break: :optimal,
      disable_wrap_by_char: true,
    )

    expect { box.render }.to raise_error(Prawn::Errors::CannotFit)
  end

  it 'only displays the selected soft hyphen' do
    pdf.font("#{Prawn::DATADIR}/fonts/DejaVuSans.ttf")
    shy = Prawn::Text::SHY
    box = Prawn::Text::Formatted::Box.new(
      [{ text: "hy#{shy}phen longwordhere" }],
      document: pdf,
      width: pdf.width_of('hy-') + 1,
      line_break: :optimal,
    )
    box.render

    strings = PDF::Inspector::Text.analyze(pdf.render).strings

    expect(box.text).to start_with("hy-\n")
    expect(strings).to include('hy-')
    expect(strings.join).not_to include(shy)
  end

  it 'does not count or render a soft hyphen at the end of the paragraph' do
    pdf.font("#{Prawn::DATADIR}/fonts/DejaVuSans.ttf")
    shy = Prawn::Text::SHY
    font = pdf.font.family
    paragraph = paragraph_for(
      [{ text: "hyphen#{shy}", font: font }],
      width: 100,
    )

    expect(paragraph.lines.first.natural_width)
      .to eq(pdf.width_of('hyphen'))
    expect(paragraph.lines.first.fragments.first[:text])
      .to eq('hyphen')
  end

  it 'measures mixed font, size and style fragments independently' do
    subscript_width = nil
    fragments = [
      { text: 'aa ' },
      { text: 'bb ', styles: [:subscript], character_spacing: 3 },
      { text: 'cc', font: 'Courier' },
    ]
    arranger = Prawn::Text::Formatted::Arranger.new(pdf, kerning: true)
    arranger.format_array = fragments
    arranger.next_string
    arranger.next_string
    subscript_width = arranger.measurement_font_settings(
      arranger.current_format_state
    ) { pdf.width_of('bb ', kerning: true) }
    paragraph = paragraph_for(fragments, width: 30)

    expect(paragraph.lines.map.with_index { |_line, index|
      line_text(paragraph, index)
    }).to eq(['aa bb', 'cc'])
    attributes = paragraph.lines.flat_map(&:fragments).flat_map(&:keys)
    expect(attributes).to include(:styles, :character_spacing, :font)
    expect(subscript_width).to be < pdf.width_of('bb ', kerning: true)
  end

  it 'penalizes consecutive hyphenated line ends' do
    line = described_class::LinePlan.new(
      fragments: [{ text: 'aa-b' }],
      natural_width: 20,
      space_count: 0,
      hyphenated: true,
      forced: false,
      paragraph_finished: false,
    )
    arranger = Prawn::Text::Formatted::Arranger.new(pdf)
    planner = described_class.new(
      pdf,
      arranger,
      width: 30,
      justify: true,
      consecutive_hyphen_penalty: 1000,
    )

    expect(planner.send(:transition_cost, line, :hard, false))
      .to eq(110)
    expect(planner.send(:transition_cost, line, :hard, true))
      .to eq(1110)
  end

  it 'includes the selected hard-hyphen penalties in the total cost' do
    paragraph = paragraph_for(
      'aa-b cc-d e',
      width: 21.6,
      consecutive_hyphen_penalty: 1000,
    )

    hyphenated_lines = paragraph.lines.map { |line|
      line.fragments.map { |fragment| fragment[:text] }.join
    }.grep(/-$/)

    expect(hyphenated_lines).to eq(['aa-', 'cc-'])
    expect(paragraph.cost).to eq(227.36000000000007)
  end

  it 'charges the forced character-break penalty' do
    pdf.font('Courier')
    paragraph = paragraph_for('abcdefgh', width: 14.4)

    expect(paragraph.lines[0...-1].count(&:forced)).to eq(3)
    expect(paragraph.cost).to eq(
      described_class::FORCED_BREAK_PENALTY * 3,
    )
  end

  it 'rejects an unknown line breaking strategy' do
    expect {
      Prawn::Text::Formatted::Box.new(
        [{ text: 'hello' }],
        document: pdf,
        line_break: :balanced,
      )
    }.to raise_error(ArgumentError, 'line_break must be either :greedy or :optimal')
  end
end
