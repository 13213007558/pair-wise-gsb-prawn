# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Footnotes do
  let(:pdf) { Prawn::Document.new(margin: 36) }

  def page_strings(pdf)
    PDF::Inspector::Page.analyze(pdf.render).pages.map { |p| p[:strings] }
  end

  def line_fragments(count)
    (1..count).flat_map { |i| [{ text: "Line #{i}" }, { text: "\n" }] }
  end

  # Number of body lines that fit on one page with the given footnote
  # reserve, measured with a throwaway dry-run box.
  def lines_that_fit(pdf, count, reserve)
    box = Prawn::Text::Formatted::Box.new(
      line_fragments(count),
      document: pdf,
      at: [0, 0],
      width: pdf.bounds.width,
      height: pdf.bounds.height - reserve,
    )
    remaining = box.render(dry_run: true)
    count - remaining.count { |f| f[:text].start_with?('Line') }
  end

  def page_capacity(pdf)
    capacity = 1
    capacity += 1 while lines_that_fit(pdf, capacity + 1, 0) == capacity + 1
    capacity
  end

  describe '#footnote_ref' do
    it 'returns a superscript marker fragment' do
      marker = pdf.footnote_ref('A note.')
      expect(marker[:text]).to eq('1')
      expect(marker[:styles]).to eq([:superscript])
      expect(marker[:footnote_id]).to eq(1)
    end

    it 'numbers footnotes sequentially in registration order' do
      expect(pdf.footnote_ref('One')[:text]).to eq('1')
      expect(pdf.footnote_ref('Two')[:text]).to eq('2')
      expect(pdf.footnote_ref('Three')[:text]).to eq('3')
    end
  end

  describe 'rendering' do
    it 'prints the footnote at the bottom of the page holding its marker' do
      pdf.formatted_text([
        { text: 'Body text' },
        pdf.footnote_ref('A footnote.'),
        { text: ' and more.' },
      ])

      analyzed = PDF::Inspector::Text.analyze(pdf.render)
      expect(pdf.page_count).to eq(1)
      expect(analyzed.strings.join).to include('1. ')
      expect(analyzed.strings.join).to include('A footnote.')

      body_y = analyzed.positions[analyzed.strings.index('Body text')].last
      note_y = analyzed.positions[analyzed.strings.index('A footnote.')].last
      expect(note_y).to be < body_y
    end

    it 'stacks multiple footnotes on one page in marker order' do
      pdf.formatted_text([
        { text: 'First' },
        pdf.footnote_ref('Note one.'),
        { text: ' and second' },
        pdf.footnote_ref('Note two.'),
      ])

      strings = page_strings(pdf).first
      expect(pdf.page_count).to eq(1)
      expect(strings.index('1. ')).to be < strings.index('2. ')
      expect(strings.join).to include('Note one.')
      expect(strings.join).to include('Note two.')
    end

    it 'places the footnote on the page the marker flows to' do
      capacity = page_capacity(pdf)
      fragments = line_fragments(capacity + 2)
      # marker sits on the second line of page 2
      fragments.insert(-3, pdf.footnote_ref('Late note.'))

      pdf.formatted_text(fragments)
      pages = page_strings(pdf)

      expect(pages.length).to eq(2)
      expect(pages[0].join).not_to include('Late note.')
      expect(pages[1].join).to include('1. ')
      expect(pages[1].join).to include('Late note.')
    end

    it 'does not render footnotes whose marker was never used' do
      pdf.footnote_ref('Orphan note.')
      pdf.text('Body without markers.')

      expect(page_strings(pdf).first.join).not_to include('Orphan note.')
    end
  end

  describe 'when the footnote pushes the last body line off the page' do
    it 'moves the footnote along without oscillating or skipping numbers' do
      note = 'Pushed note.'
      reserve = Prawn::Footnotes::FOOTNOTE_RULE_SPACE +
        pdf.height_of_formatted(
          [
            { text: '1. ', size: Prawn::Footnotes::FOOTNOTE_FONT_SIZE },
            { text: note, size: Prawn::Footnotes::FOOTNOTE_FONT_SIZE },
            { text: "\n", size: Prawn::Footnotes::FOOTNOTE_FONT_SIZE },
          ],
          width: pdf.bounds.width,
        )

      capacity = page_capacity(pdf)
      fit_with_reserve = lines_that_fit(pdf, capacity, reserve)
      expect(fit_with_reserve).to be < capacity

      # Body fills exactly one line more than fits next to the footnote,
      # so adding the footnote pushes exactly the last line off the page.
      body_lines = fit_with_reserve + 1
      expect(body_lines).to be <= capacity

      fragments = line_fragments(body_lines)
      fragments.insert(-2, pdf.footnote_ref(note))
      fragments += [
        { text: 'Tail' },
        pdf.footnote_ref('Second note.'),
        { text: ' end' },
      ]

      pdf.formatted_text(fragments)
      pages = page_strings(pdf)

      # Stable layout: exactly two pages, no oscillation.
      expect(pages.length).to eq(2)

      # The last line and its marker were pushed to page 2.
      expect(pages[0].join).to include("Line #{body_lines - 1}")
      expect(pages[0].join).not_to include("Line #{body_lines}")
      expect(pages[1].join).to include("Line #{body_lines}")

      # The footnote follows its marker: no footnote on page 1, both
      # footnotes on page 2.
      expect(pages[0].join).not_to include(note)
      expect(pages[1].join).to include(note)

      # Numbering is assigned in registration order and does not skip.
      expect(pages[1].join).to include('1. ')
      expect(pages[1].join).to include('2. ')
      expect(pages[1].join).to include('Second note.')
    end
  end

  describe 'oversized footnotes' do
    it 'splits a footnote taller than one page across pages' do
      long_note = ('word ' * 2500).strip
      pdf.formatted_text([
        { text: 'Intro line' },
        { text: "\n" },
        { text: 'Marker line' },
        pdf.footnote_ref(long_note),
        { text: "\n" },
        { text: 'After text' },
      ])

      pages = page_strings(pdf)
      expect(pages.length).to be > 1

      # The marker stays on page 1 and the footnote starts below it.
      expect(pages[0].join).to include('Marker line')
      expect(pages[0].join).to include('1. ')
      expect(pages[0].join).to include('word')

      # The remainder continues at the bottom of the following page.
      expect(pages[1].join).to include('word')
      expect(pages[1].join).not_to include('1. ')
    end

    it 'raises CannotFit for unbreakable content taller than one page' do
      pdf.formatted_text([
        { text: 'Body' },
        pdf.footnote_ref('X', size: 800),
      ])

      expect { pdf.render }.to raise_error(Prawn::Errors::CannotFit)
    end
  end

  describe 'trial layout safety' do
    it 'does not run fragment callbacks during dry runs' do
      callback = Class.new do
        attr_reader :count

        def initialize
          @count = 0
        end

        def render_in_front(_fragment)
          @count += 1
        end
      end.new

      fragments = [{ text: 'Body', callback: callback }]
      fragments << pdf.footnote_ref('A note.')
      fragments += (1..60).flat_map do |i|
        [{ text: " filler #{i}" }, { text: "\n" }]
      end
      pdf.formatted_text(fragments)
      pdf.render

      expect(callback.count).to eq(1)
    end

    it 'does not add PDF objects during trial layouts' do
      plain = Prawn::Document.new(margin: 36)
      plain.text('Body')

      footnoted = Prawn::Document.new(margin: 36)
      footnoted.formatted_text([
        { text: 'Body' },
        footnoted.footnote_ref('A note.'),
      ])

      expect(footnoted.state.store.size).to eq(plain.state.store.size)

      footnoted.render
      plain.render
      expect(footnoted.state.store.size).to eq(plain.state.store.size)
    end
  end
end
