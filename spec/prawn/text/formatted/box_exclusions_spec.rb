# frozen_string_literal: true

require 'spec_helper'
require 'pdf/reader'
require 'stringio'

describe Prawn::Text::Formatted::Box do
  let(:pdf) { create_pdf }

  def lines_with_positions(pdf)
    text = PDF::Inspector::Text.analyze(pdf.render)
    text.strings.zip(text.positions)
  end

  describe 'with :exclusions option' do
    it 'flows text around a rectangular exclusion' do
      box = described_class.new(
        [{ text: (1..120).map { |i| "word#{i}" }.join(' ') }],
        document: pdf,
        at: [0, 792],
        width: 612,
        height: 792,
        exclusions: [[[200, 700], [400, 700], [400, 500], [200, 500]]],
      )
      remaining = box.render

      expect(remaining).to eq([])
      expect(box.everything_printed?).to be(true)

      lines_with_positions(pdf).each do |string, (x, y)|
        next unless y < 700 && y > 500

        width = pdf.width_of(string)
        # no drawn text may overlap the excluded rectangle
        expect((x + width) <= 200.5 || (x + width) >= 399.5).to be(true)
      end
    end

    it 'uses the intervals on both sides of an exclusion on the same line' do
      described_class.new(
        [{ text: (1..120).map { |i| "word#{i}" }.join(' ') }],
        document: pdf,
        at: [0, 792],
        width: 612,
        height: 792,
        exclusions: [[[200, 700], [400, 700], [400, 500], [200, 500]]],
      ).render

      split_line = lines_with_positions(pdf).select do |_string, (_x, y)|
        (y - 700.2).abs < 1
      end
      expect(split_line.map(&:first)).to eq(
        ['word86 word87 word88 word89', 'word90 word91 word92 word93 word94'],
      )
      expect(split_line.map { |_string, (x, _y)| x }).to eq([0.0, 400.0])
    end

    it 'preserves reading order across split segments' do
      words = (1..60).map { |i| "w#{i}" }
      described_class.new(
        [{ text: words.join(' ') }],
        document: pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: [[[200, 400], [400, 400], [400, 300], [200, 300]]],
      ).render

      strings = PDF::Inspector::Text.analyze(pdf.render).strings
      printed_words = strings.join(' ').split
      expect(printed_words).to eq(words)
    end

    it 'flows text into the pocket of a concave polygon' do
      # sideways U shape: arms cover x 100..300 above y 300 and below y 200,
      # the pocket between them only excludes x 100..200
      described_class.new(
        [{ text: (1..200).map { |i| "w#{i}" }.join(' ') }],
        document: pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: [
          [
            [100, 400], [300, 400], [300, 300], [200, 300],
            [200, 200], [300, 200], [300, 100], [100, 100],
          ],
        ],
      ).render

      lines = lines_with_positions(pdf)

      arm_lines = lines.select { |_s, (x, y)| y.between?(305, 399) && x > 0 }
      expect(arm_lines).not_to be_empty
      arm_lines.each do |_string, (x, _y)|
        expect(x).to be_within(0.5).of(300)
      end

      pocket_lines = lines.select { |_s, (x, y)| y.between?(205, 292) && x > 0 }
      expect(pocket_lines).not_to be_empty
      pocket_lines.each do |_string, (x, _y)|
        expect(x).to be_within(0.5).of(200)
      end
    end

    it 'flows text around multiple disjoint polygons' do
      described_class.new(
        [{ text: (1..100).map { |i| "w#{i}" }.join(' ') }],
        document: pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: [
          [[0, 400], [290, 400], [290, 100], [0, 100]],
          [[320, 400], [612, 400], [612, 100], [320, 100]],
        ],
      ).render

      lines_with_positions(pdf).each do |string, (x, y)|
        next unless y > 100

        width = pdf.width_of(string)
        # only the 30pt wide channel between the polygons is available
        expect(x).to be >= 289.5
        expect(x + width).to be <= 320.5
      end
    end

    it 'threads text through a narrow channel and continues below' do
      words = (1..100).map { |i| "w#{i}" }
      box = described_class.new(
        [{ text: words.join(' ') }],
        document: pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: [
          [[0, 400], [290, 400], [290, 100], [0, 100]],
          [[320, 400], [612, 400], [612, 100], [320, 100]],
        ],
      )
      remaining = box.render

      expect(remaining).to eq([])
      expect(box.everything_printed?).to be(true)

      strings = PDF::Inspector::Text.analyze(pdf.render).strings
      expect(strings.join(' ').split).to eq(words)
    end

    it 'accounts for the actual line height with mixed font sizes' do
      described_class.new(
        [
          { text: 'small words here and there ', size: 10 },
          { text: 'BIGWORD ', size: 30 },
          { text: 'and more small words to follow on', size: 10 },
        ],
        document: pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: [[[100, 395], [500, 395], [500, 370], [100, 370]]],
      ).render

      lines_with_positions(pdf).each do |string, (x, y)|
        next unless y < 395 && y > 360

        font_size = string == string.upcase ? 30 : 10
        pdf.font_size = font_size
        width = pdf.width_of(string)
        # text on lines intersecting the exclusion must avoid it
        expect((x + width) <= 100.5 || (x + width) >= 499.5).to be(true)
      end
    end

    it 'accounts for superscripts raising the line band' do
      exclusion = [[[0, 381], [100, 381], [100, 377], [0, 377]]]

      plain_pdf = create_pdf
      plain_pdf.font_size = 20
      described_class.new(
        [{ text: "aaaa\n" }, { text: 'bb', size: 20 }, { text: 'cc' }],
        document: plain_pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: exclusion,
      ).render

      sup_pdf = create_pdf
      sup_pdf.font_size = 20
      described_class.new(
        [
          { text: "aaaa\n" },
          { text: 'bb', size: 20 },
          { text: 'cc', styles: [:superscript] },
        ],
        document: sup_pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: exclusion,
      ).render

      plain_second_line = lines_with_positions(plain_pdf).select do |_s, (_x, y)|
        y < 380
      end
      expect(plain_second_line.map { |_s, (x, _y)| x }.min).to be < 1

      sup_second_line = lines_with_positions(sup_pdf).select do |_s, (_x, y)|
        y < 380
      end
      # the superscript reaches into the exclusion band, so the whole line
      # moves past the excluded interval
      expect(sup_second_line.map { |_s, (x, _y)| x }.min).to be > 99
    end

    it 'places link annotations over the right segments' do
      described_class.new(
        [
          { text: 'hello ', link: 'http://a.example' },
          { text: 'world', link: 'http://b.example' },
        ],
        document: pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        character_spacing: 2,
        exclusions: [[[40, 400], [500, 400], [500, 380], [40, 380]]],
      ).render

      reader = PDF::Reader.new(StringIO.new(pdf.render))
      annotations = reader.page(1).attributes[:Annots].map do |ref|
        reader.page(1).objects.deref(ref)
      end
      rects = annotations.map { |a| a[:Rect] }
      uris = annotations.map { |a| a.dig(:A, :URI) }

      expect(uris).to eq(['http://a.example', 'http://b.example'])
      # first link sits in the left interval, second in the right one
      expect(rects[0][0]).to be_within(0.5).of(0)
      expect(rects[0][2]).to be_within(0.5).of(33.3)
      expect(rects[1][0]).to be_within(0.5).of(500)
      expect(rects[1][2]).to be_within(0.5).of(536.7)
    end

    it 'respects character spacing when sizing segments' do
      words = (1..60).map { |i| "w#{i}" }.join(' ')

      first_segments = [0, 3].map do |spacing|
        spaced_pdf = create_pdf
        described_class.new(
          [{ text: words }],
          document: spaced_pdf,
          at: [0, 400],
          width: 612,
          height: 400,
          character_spacing: spacing,
          exclusions: [[[200, 400], [400, 400], [400, 300], [200, 300]]],
        ).render

        lines_with_positions(spaced_pdf)
          .select { |_s, (x, y)| x < 1 && y > 390 }
          .map(&:first)
          .first
      end

      # wider character spacing leaves fewer words in the same interval
      expect(first_segments[1].split.length)
        .to be < first_segments[0].split.length
    end

    it 'pushes the baseline down when no interval can hold a glyph' do
      box = described_class.new(
        [{ text: 'hello world' }],
        document: pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: [[[0, 400], [612, 400], [612, 390], [0, 390]]],
      )
      remaining = box.render

      expect(remaining).to eq([])
      strings = PDF::Inspector::Text.analyze(pdf.render).strings
      expect(strings.join).to include('hello')
    end

    it 'gives up instead of looping when exclusions cover the whole box' do
      box = described_class.new(
        [{ text: 'hello world' }],
        document: pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: [[[0, 500], [612, 500], [612, 0], [0, 0]]],
      )

      remaining = nil
      expect { remaining = box.render }.not_to raise_error

      expect(box.nothing_printed?).to be(true)
      expect(box.everything_printed?).to be(false)
      expect(remaining.map { |hash| hash[:text] }.join).to eq('hello world')
    end

    it 'keeps text intact when a channel is too narrow for any glyph' do
      box = described_class.new(
        [{ text: 'alpha beta gamma delta' }],
        document: pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: [
          [[0, 400], [290, 400], [290, 100], [0, 100]],
          [[293, 400], [612, 400], [612, 100], [293, 100]],
        ],
      )
      remaining = box.render

      # nothing fits in the 3pt wide channel; text continues below
      expect(remaining).to eq([])
      strings = PDF::Inspector::Text.analyze(pdf.render).strings
      expect(strings.join).to eq('alpha beta gamma delta')
    end

    it 'reports unprinted text when a narrow channel covers the whole box' do
      box = described_class.new(
        [{ text: 'alpha beta' }],
        document: pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: [
          [[0, 400], [290, 400], [290, 0], [0, 0]],
          [[293, 400], [612, 400], [612, 0], [293, 0]],
        ],
      )
      remaining = box.render

      expect(box.nothing_printed?).to be(true)
      expect(remaining.map { |hash| hash[:text] }.join).to eq('alpha beta')
    end

    it 'still raises CannotFit for a too-narrow box without exclusions in the way' do
      box = described_class.new(
        [{ text: 'hello' }],
        document: pdf,
        at: [0, 400],
        width: 1,
        height: 400,
        exclusions: [[[100, 400], [200, 400], [200, 0], [100, 0]]],
      )

      expect { box.render }.to raise_error(Prawn::Errors::CannotFit)
    end

    it 'returns unprinted text that can continue on the next page' do
      words = (1..2000).map { |i| "w#{i}" }
      pdf.formatted_text(
        [{ text: words.join(' ') }],
        exclusions: [[[0, 792], [612, 792], [612, 600], [0, 600]]],
      )

      expect(pdf.page_count).to be > 1

      reader = PDF::Reader.new(StringIO.new(pdf.render))
      printed = reader.pages.flat_map { |page| page.text.split }
      expect(printed).to eq(words)
    end

    it 'keeps text below a full-width exclusion on every page' do
      pdf.formatted_text(
        [{ text: (1..2000).map { |i| "w#{i}" }.join(' ') }],
        exclusions: [[[0, 792], [612, 792], [612, 600], [0, 600]]],
      )

      text = PDF::Inspector::Text.analyze(pdf.render)
      text.positions.each do |(_x, y)|
        expect(y).to be < 600
      end
    end

    it 'supports dry runs without inking the page' do
      box = described_class.new(
        [{ text: (1..60).map { |i| "w#{i}" }.join(' ') }],
        document: pdf,
        at: [0, 400],
        width: 612,
        height: 400,
        exclusions: [[[200, 400], [400, 400], [400, 300], [200, 300]]],
      )
      box.render(dry_run: true)

      expect(box.everything_printed?).to be(true)
      expect(box.height).to be > 0
      expect(PDF::Inspector::Text.analyze(pdf.render).strings).to be_empty
    end
  end
end
