# frozen_string_literal: true

require 'spec_helper'

describe 'Unicode bidirectional PDF text' do
  let(:pdf) { create_pdf }

  before do
    pdf.font(File.join(Prawn::DATADIR, 'fonts', 'DejaVuSans.ttf'))
  end

  it 'keeps mixed text logical while placing glyphs visually' do
    logical_text = "\u0639 123 AB"
    pdf.text_box(
      logical_text,
      bidi: true,
      direction: :rtl,
      at: [50, 750],
      width: 300,
    )

    output = pdf.render
    rendered = StringIO.new(output)

    PDF::Reader.open(rendered) do |reader|
      expect(reader.pages.first.text).to eq(logical_text)
    end

    inspector = PDF::Inspector::Text.analyze(output)
    strings = inspector.strings

    expect(strings).to include('123')
    expect(strings).to include('AB')
    expect(strings).not_to include('321')
    expect(strings).not_to include('BA')
  end

  it 'reapplies bidi rules after wrapping and keeps every line logical' do
    logical_text = "\u0639\u0644\u0627 123 " * 6
    pdf.text_box(logical_text, bidi: true, direction: :rtl, width: 120)

    output = pdf.render
    PDF::Reader.open(StringIO.new(output)) do |reader|
      lines = reader.pages.first.text.lines.map(&:chomp)

      expect(lines.length).to be > 1
      expect(lines).to all(include('123'))
      expect(lines.join).to start_with(logical_text[0, 12])
    end
  end

  it 'splits a link annotation across visual runs' do
    pdf.formatted_text_box(
      [{ text: "\u0639 123 AB", link: 'https://example.com/' }],
      at: [50, 750],
      width: 300,
      direction: :rtl,
      bidi: true,
    )

    output = pdf.render
    PDF::Reader.open(StringIO.new(output)) do |reader|
      page = reader.pages.first
      annotations = page.attributes[:Annots].map { |reference|
        reader.objects.deref(reference)
      }

      expect(annotations.length).to be >= 3
      expect(annotations.map { |annotation|
        annotation[:A][:URI]
      }.uniq).to eq(['https://example.com/'])

      rectangles = annotations.map { |annotation|
        annotation[:Rect].map { |value| value.round(2) }
      }
      expect(rectangles.map { |rect| rect[0] }).to eq(
        rectangles.map { |rect| rect[0] }.sort,
      )
    end
  end

  it 'mirrors brackets visually while retaining the logical bracket' do
    logical_text = '(123)'
    pdf.text_box(
      logical_text,
      bidi: true,
      direction: :rtl,
      at: [50, 750],
      width: 300,
    )

    rendered = pdf.render

    PDF::Reader.open(StringIO.new(rendered)) do |reader|
      expect(reader.pages.first.text).to eq(logical_text)
    end

    inspector = PDF::Inspector::Text.analyze(rendered)
    expect(inspector.strings).to include(')')
    expect(inspector.strings).to include('(')
  end

  it 'honors isolate and override controls' do
    text = "\u2067abc\u2069 \u0639"
    pdf.text_box(
      text,
      bidi: true,
      direction: :rtl,
      at: [50, 750],
      width: 300,
    )

    expected = Prawn::Text::Bidi.logical_text_without_controls(text)
    output = pdf.render
    PDF::Reader.open(StringIO.new(output)) do |reader|
      expect(reader.pages.first.text).to eq(expected)
    end
  end
end
