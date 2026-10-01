# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Footnotes do
  def runs_by_page(document)
    output = document.render
    PDF::Reader.open(StringIO.new(output)) do |reader|
      reader.pages.map do |page|
        page.runs.map do |run|
          {
            text: run.text,
            x: run.x,
            y: run.y,
            font_size: run.font_size,
          }
        end
      end
    end
  end

  def markers(runs, number)
    runs.select { |run| run[:text] == number.to_s }
  end

  it 'keeps multiple anchors and their notes on the same page without overlap' do
    document = Prawn::Document.new(
      page_size: [220, 300],
      margin: 20,
    )
    first = document.footnote('First note', text_options: { size: 10 })
    second = document.footnote('Second note', text_options: { size: 10 })

    document.formatted_text(
      [
        { text: 'Body one ' },
        first,
        { text: ' body two ' },
        second,
        { text: ' body three' },
      ],
      size: 12,
    )

    pages = runs_by_page(document)
    expect(pages.size).to eq(1)
    expect(markers(pages[0], 1).size).to eq(1)
    expect(markers(pages[0], 2).size).to eq(1)
    expect(pages[0].map { |run| run[:text] })
      .to include('1. First note', '2. Second note')

    note_label_top = pages[0]
      .select { |run| run[:text].match?(/\A[12]\./) }
      .map { |run| run[:y] + run[:font_size] }
      .max
    notes = pages[0].select { |run| run[:y] <= note_label_top }
    body_bottom = pages[0]
      .reject { |run| run[:y] <= note_label_top }
      .map { |run| run[:y] - run[:font_size] }
      .min
    expect(notes.map { |run| run[:y] }.max).to be < body_bottom
  end

  it 'continues a long footnote on the following page using caller text' do
    document = Prawn::Document.new(
      page_size: [220, 300],
      margin: 20,
    )
    footnote = document.footnote(
      'Long note text. ' * 80,
      continuation: ->(number) {
        [{ text: "[continued #{number}] ", styles: [:bold] }]
      },
      text_options: { size: 8 },
    )

    document.formatted_text(
      [
        { text: 'Intro words. ' * 30 },
        footnote,
        { text: ' Tail words.' },
      ],
      size: 10,
    )

    pages = runs_by_page(document)
    expect(pages.size).to eq(2)
    expect(markers(pages[0], 1).size).to eq(1)
    expect(markers(pages[1], 1)).to be_empty
    expect(pages[0].any? { |run| run[:text].start_with?('1. Long note') })
      .to be true
    expect(pages[1].any? { |run| run[:text].start_with?('[continued 1]') })
      .to be true

    first_note_top = pages[0]
      .select { |run| run[:text].include?('Long note') }
      .map { |run| run[:y] + run[:font_size] }
      .max
    first_body_bottom = pages[0]
      .reject { |run| run[:text].include?('Long note') }
      .map { |run| run[:y] - run[:font_size] }
      .min
    expect(first_note_top).to be < first_body_bottom

    continuation_top = pages[1]
      .select { |run| run[:text].include?('Long note') }
      .map { |run| run[:y] + run[:font_size] }
      .max
    continuation_body_bottom = pages[1]
      .reject { |run| run[:text].include?('Long note') }
      .map { |run| run[:y] - run[:font_size] }
      .min
    expect(continuation_top).to be < continuation_body_bottom
  end

  it 'accepts caller-provided continuation text as a string' do
    document = Prawn::Document.new(page_size: [220, 300], margin: 20)
    footnote = document.footnote(
      'Long note text. ' * 80,
      continuation: 'Custom continuation: ',
      text_options: { size: 8 },
    )

    document.formatted_text(
      [
        { text: 'Intro words. ' * 30 },
        footnote,
        { text: ' Tail words.' },
      ],
      size: 10,
    )

    pages = runs_by_page(document)
    expect(pages[1].any? { |run| run[:text].start_with?('Custom continuation:') })
      .to be true
  end

  it 'does not silently overlap inside a nested bounding box' do
    document = Prawn::Document.new
    footnote = document.footnote('Nested note')

    document.bounding_box([0, document.cursor], width: 100) do
      expect {
        document.formatted_text([{ text: 'Body ' }, footnote])
      }.to raise_error(ArgumentError, /margin box/i)
    end
  end

  it 'moves an anchor to the next page when its paragraph is repaginated' do
    document = Prawn::Document.new(
      page_size: [220, 240],
      margin: 20,
    )
    footnote = document.footnote(
      'Anchor page note with enough text to require substantial space. ' * 5,
      text_options: { size: 8 },
    )

    document.formatted_text(
      [
        { text: 'Repaginated body. ' * 25 },
        footnote,
        { text: ' anchor ending.' },
      ],
      size: 12,
    )

    pages = runs_by_page(document)
    expect(pages.size).to eq(2)
    first_page_text = pages[0].map { |run| run[:text] }.join(' ')
    second_page_text = pages[1].map { |run| run[:text] }.join(' ')
    expect(first_page_text).not_to include('Anchor page note')
    expect(markers(pages[0], 1)).to be_empty
    expect(markers(pages[1], 1).size).to eq(1)
    expect(second_page_text).to include('Anchor page note')
  end

  it 'keeps numbering stable after a failed same-page attempt is rolled back' do
    document = Prawn::Document.new(
      page_size: [220, 240],
      margin: 20,
    )
    footnote = document.footnote(
      'Anchor page note with enough text to require substantial space. ' * 5,
      text_options: { size: 8 },
    )

    document.formatted_text(
      [
        { text: 'Repaginated body. ' * 25 },
        footnote,
        { text: ' anchor ending.' },
      ],
      size: 12,
    )
    later = document.footnote('Later note')
    document.formatted_text([{ text: 'Later body ' }, later], size: 12)

    pages = runs_by_page(document)
    all_text = pages.flat_map { |runs| runs.map { |run| run[:text] } }
    expect(all_text.count('1')).to eq(1)
    expect(all_text.count('2')).to eq(1)
    expect(all_text).to include('2. Later note')
  end

  it 'raises a clear error when a footnote cannot fit with its anchor' do
    document = Prawn::Document.new(
      page_size: [200, 45],
      margin: 5,
    )
    footnote = document.footnote('Footnote word. ' * 20)

    expect {
      document.formatted_text(
        [{ text: 'Body ', styles: [:bold] }, footnote],
        size: 18,
      )
    }.to raise_error(
      Prawn::Errors::FootnotesCannotFit,
      /same page as its anchor|not enough total height/i,
    )

    expect(pdf_page_count(document)).to eq(1)
  end

  def pdf_page_count(document)
    PDF::Reader.open(StringIO.new(document.render), &:page_count)
  end
end
