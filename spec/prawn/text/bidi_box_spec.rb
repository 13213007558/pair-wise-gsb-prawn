# frozen_string_literal: true

require 'spec_helper'

describe 'Bidirectional text layout' do
  let(:pdf) { create_pdf }
  let(:font_path) { "#{Prawn::DATADIR}/fonts/DejaVuSans.ttf" }

  before { pdf.font(font_path) }

  def text_analysis(pdf)
    PDF::Inspector::Text.analyze(pdf.render)
  end

  def annotations(pdf)
    reader = PDF::Reader.new(StringIO.new(pdf.render))
    page = reader.pages.first
    annots = page.objects.deref(page.attributes[:Annots]) || []
    annots.map { |ref| page.objects.deref(ref) }
  end

  describe 'logical text preservation' do
    it 'keeps logical order in text extraction for mixed text' do
      pdf.text_box("abc \u05D0\u05D1\u05D2 def", bidi: true, at: [0, 700])
      expect(text_analysis(pdf).strings.join).to eq(
        "abc \u05D0\u05D1\u05D2 def",
      )
    end

    it 'keeps logical order for RTL paragraphs with digits and Latin' do
      pdf.text_box(
        "\u05E9\u05DC\u05D5\u05DD hello 123", bidi: true, at: [0, 700],
      )
      expect(text_analysis(pdf).strings.join).to eq(
        "\u05E9\u05DC\u05D5\u05DD hello 123",
      )
    end

    it 'keeps logical order with explicit controls' do
      pdf.text_box(
        "a\u202B\u05D0\u05D1\u202Cb\u2066\u05D2\u2069c",
        bidi: true,
        at: [0, 700],
      )
      expect(text_analysis(pdf).strings.join).to eq(
        "a\u202B\u05D0\u05D1\u202Cb\u2066\u05D2\u2069c",
      )
    end

    it 'returns logical text from Box#text' do
      box = Prawn::Text::Formatted::Box.new(
        [{ text: "abc \u05D0\u05D1\u05D2 def" }],
        document: pdf,
        bidi: true,
        at: [0, 700],
      )
      box.render
      expect(box.text).to eq("abc \u05D0\u05D1\u05D2 def")
    end

    it 'returns unprinted text in logical order' do
      box = Prawn::Text::Formatted::Box.new(
        [{ text: "\u05D0\u05D1\u05D2 \u05D3\u05D4\u05D5 \u05D6\u05D7\u05D8" }],
        document: pdf,
        bidi: true,
        at: [0, 700],
        width: pdf.width_of("\u05D0\u05D1\u05D2 \u05D3\u05D4\u05D5"),
        height: pdf.font.height,
      )
      remaining = box.render
      expect(remaining.map { |fragment| fragment[:text] }.join).to eq(
        "\u05D6\u05D7\u05D8",
      )
    end
  end

  describe 'visual order' do
    it 'displays an RTL run right-to-left inside an LTR paragraph' do
      pdf.text_box("ab \u05D0\u05D1\u05D2", bidi: true, at: [0, 700])
      analysis = text_analysis(pdf)
      strings = analysis.strings
      positions = analysis.positions

      hebrew = strings.each_index.select { |i| strings[i] =~ /\u05D0/ }
      # logical order in the content stream: \u05D0 then \u05D1 then \u05D2
      alef = strings.index("\u05D0")
      bet = strings.index("\u05D1")
      gimel = strings.index("\u05D2")
      expect(alef).to be < bet
      expect(bet).to be < gimel
      # visual order: \u05D2 left of \u05D1 left of \u05D0
      expect(positions[gimel][0]).to be < positions[bet][0]
      expect(positions[bet][0]).to be < positions[alef][0]
      expect(hebrew).not_to be_empty
    end

    it 'displays an LTR run inside an RTL paragraph left-to-right' do
      pdf.text_box(
        "\u05D0\u05D1\u05D2 ab \u05D3\u05D4",
        bidi: true,
        at: [0, 700],
      )
      analysis = text_analysis(pdf)
      strings = analysis.strings
      positions = analysis.positions

      ab = strings.index { |s| s.include?('ab') }
      alef = strings.index("\u05D0")
      # the Latin run displays to the left of the first Hebrew letter
      expect(positions[ab][0]).to be < positions[alef][0]
    end

    it 'keeps digits left-to-right inside RTL text' do
      pdf.text_box("\u05D0\u05D112\u05D2", bidi: true, at: [0, 700])
      analysis = text_analysis(pdf)
      strings = analysis.strings
      positions = analysis.positions

      digits = strings.index('12')
      alef = strings.index("\u05D0")
      bet = strings.index("\u05D1")
      gimel = strings.index("\u05D2")
      # visual: \u05D1 \u05D0 ... \u05D2 with the digit run on the left edge
      expect(positions[digits][0]).to be < positions[bet][0]
      expect(positions[digits][0]).to be > positions[gimel][0]
    end

    it 'places an RTL paragraph according to the detected direction' do
      pdf.text_box("\u05D0\u05D1\u05D2 ab", bidi: true, at: [0, 700])
      analysis = text_analysis(pdf)
      strings = analysis.strings
      positions = analysis.positions

      # RTL paragraph: the Hebrew word displays right of the Latin word
      alef = strings.index("\u05D0")
      ab = strings.index { |s| s.include?('ab') }
      expect(positions[alef][0]).to be > positions[ab][0]
    end
  end

  describe 'line wrapping' do
    it 're-applies line-level rules after wrapping' do
      box = Prawn::Text::Formatted::Box.new(
        [{ text: "\u05D0\u05D1\u05D2 \u05D3\u05D4\u05D5" }],
        document: pdf,
        bidi: true,
        at: [0, 700],
        width: pdf.width_of("\u05D0\u05D1\u05D2 \u05D3"),
      )
      box.render
      expect(box.text).to eq("\u05D0\u05D1\u05D2\n\u05D3\u05D4\u05D5")

      analysis = text_analysis(pdf)
      expect(analysis.strings.join).to include("\u05D0\u05D1\u05D2")
      expect(analysis.strings.join).to include("\u05D3\u05D4\u05D5")
    end
  end

  describe 'link annotations' do
    it 'creates one annotation per visual segment of a link' do
      pdf.formatted_text_box(
        [{ text: "\u05D0\u05D112\u05D2", link: 'http://example.com' }],
        bidi: true,
        direction: :rtl,
        at: [0, 700],
        width: 400,
      )
      annots = annotations(pdf)
      # \u05D0\u05D1, 12 and \u05D2 are three separate visual runs
      expect(annots.length).to eq(3)
      rects = annots.map { |a| a[:Rect] }.sort_by(&:first)
      rects.each_cons(2) do |first, second|
        expect(second[0]).to be_within(0.01).of(first[2])
      end
    end

    it 'keeps a single annotation for a visually contiguous link' do
      pdf.formatted_text_box(
        [{ text: "\u05D0\u05D1\u05D2", link: 'http://example.com' }],
        bidi: true,
        at: [0, 700],
      )
      expect(annotations(pdf).length).to eq(1)
    end
  end

  describe 'paragraph direction' do
    it 'uses the explicit direction when given' do
      pdf.text_box(
        "\u05D0\u05D1\u05D2 ab",
        bidi: true,
        direction: :ltr,
        at: [0, 700],
      )
      analysis = text_analysis(pdf)
      strings = analysis.strings
      positions = analysis.positions

      # LTR paragraph: Hebrew word displays left of the Latin word
      alef = strings.index("\u05D0")
      ab = strings.index { |s| s.include?('ab') }
      expect(positions[alef][0]).to be < positions[ab][0]
    end
  end
end
