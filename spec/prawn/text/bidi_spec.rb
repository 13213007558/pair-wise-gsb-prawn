# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Text::Bidi do
  describe 'conformance vectors' do
    vectors_file = File.join(
      Prawn::BASEDIR, 'spec', 'data', 'bidi_test_vectors.txt',
    )
    vectors = File.readlines(vectors_file).map(&:strip).reject { |line|
      line.empty? || line.start_with?('#')
    }

    vectors.each_with_index do |vector, index|
      codepoints_s, para_dir_s, para_level_s, levels_s, visual_s =
        vector.split(';')
      codepoints = codepoints_s.split.map { |c| c.to_i(16) }
      string = codepoints.pack('U*')
      para_dir = para_dir_s.to_i
      expected_para_level = para_level_s.to_i
      expected_levels = levels_s.split.map(&:to_i)
      expected_visual = visual_s.split.map(&:to_i)
      base_direction =
        case para_dir
        when 0 then :ltr
        when 1 then :rtl
        end

      it "resolves vector #{index + 1} (#{codepoints_s})" do
        levels, paragraph_level = described_class.resolve_levels(
          string,
          base_direction: base_direction,
        )
        expect(levels).to eq(expected_levels)
        expect(paragraph_level).to eq(expected_para_level)
        expect(
          described_class.reorder_indices(levels, paragraph_level),
        ).to eq(expected_visual)
        expect(
          described_class.visual_order(
            string,
            base_direction: base_direction,
          ),
        ).to eq(expected_visual)
      end
    end
  end

  describe '.bidi_class' do
    it 'classifies representative code points' do
      expect(described_class.bidi_class('A'.ord)).to eq(:L)
      expect(described_class.bidi_class(0x05D0)).to eq(:R)
      expect(described_class.bidi_class(0x0627)).to eq(:AL)
      expect(described_class.bidi_class('0'.ord)).to eq(:EN)
      expect(described_class.bidi_class(0x0660)).to eq(:AN)
      expect(described_class.bidi_class(' '.ord)).to eq(:WS)
      expect(described_class.bidi_class('+'.ord)).to eq(:ES)
      expect(described_class.bidi_class(','.ord)).to eq(:CS)
      expect(described_class.bidi_class('$'.ord)).to eq(:ET)
      expect(described_class.bidi_class('('.ord)).to eq(:ON)
      expect(described_class.bidi_class(0x202A)).to eq(:LRE)
      expect(described_class.bidi_class(0x202B)).to eq(:RLE)
      expect(described_class.bidi_class(0x202C)).to eq(:PDF)
      expect(described_class.bidi_class(0x202D)).to eq(:LRO)
      expect(described_class.bidi_class(0x202E)).to eq(:RLO)
      expect(described_class.bidi_class(0x2066)).to eq(:LRI)
      expect(described_class.bidi_class(0x2067)).to eq(:RLI)
      expect(described_class.bidi_class(0x2068)).to eq(:FSI)
      expect(described_class.bidi_class(0x2069)).to eq(:PDI)
      expect(described_class.bidi_class(0x0591)).to eq(:NSM)
    end

    it 'defaults unlisted code points to L' do
      expect(described_class.bidi_class(0x0378)).to eq(:L)
    end
  end

  describe 'paragraph direction' do
    it 'defaults to LTR when there is no strong character' do
      _levels, paragraph_level = described_class.resolve_levels('123 ()')
      expect(paragraph_level).to eq(0)
    end

    it 'uses the first strong character' do
      _levels, paragraph_level =
        described_class.resolve_levels("abc \u05D0")
      expect(paragraph_level).to eq(0)

      _levels, paragraph_level =
        described_class.resolve_levels("\u05D0 abc")
      expect(paragraph_level).to eq(1)

      _levels, paragraph_level =
        described_class.resolve_levels("123 \u0627")
      expect(paragraph_level).to eq(1)
    end

    it 'skips isolate content when detecting the paragraph direction' do
      _levels, paragraph_level =
        described_class.resolve_levels("\u2066\u05D0\u2069 abc")
      expect(paragraph_level).to eq(0)
    end

    it 'can be forced with base_direction' do
      _levels, paragraph_level = described_class.resolve_levels(
        "\u05D0\u05D1",
        base_direction: :ltr,
      )
      expect(paragraph_level).to eq(0)
    end
  end

  describe 'explicit embeddings and overrides' do
    it 'handles RLE...PDF' do
      levels, = described_class.resolve_levels(
        "a\u202Bbc\u202Cd",
        base_direction: :ltr,
      )
      expect(levels[2]).to eq(2)
      expect(levels[3]).to eq(2)
    end

    it 'handles nested embeddings' do
      levels, = described_class.resolve_levels(
        "a\u202Ab\u202B\u05D0\u202Cc\u202Cd",
        base_direction: :ltr,
      )
      expect(levels[4]).to eq(3)
    end

    it 'applies directional overrides' do
      order = described_class.visual_order(
        "a\u202Ebc\u202Cd",
        base_direction: :ltr,
      )
      expect(order).to eq([0, 3, 2, 1, 4, 5])
    end
  end

  describe 'isolates' do
    it 'keeps isolate content together' do
      order = described_class.visual_order(
        "a\u2067\u05D0\u05D1\u2069b",
        base_direction: :ltr,
      )
      expect(order).to eq([0, 1, 3, 2, 4, 5])
    end

    it 'resolves FSI direction from its content' do
      levels_ltr, = described_class.resolve_levels(
        "a\u2068bc\u2069d",
        base_direction: :ltr,
      )
      expect(levels_ltr[2]).to eq(2)

      levels_rtl, = described_class.resolve_levels(
        "a\u2068\u05D0\u2069d",
        base_direction: :ltr,
      )
      expect(levels_rtl[2]).to eq(1)
    end
  end

  describe '.visual_runs' do
    it 'returns runs in visual order with logical ranges' do
      runs = described_class.visual_runs(
        "abc \u05D0\u05D1\u05D2 def",
        base_direction: :ltr,
      )
      expect(runs).to eq(
        [
          { level: 0, start: 0, length: 4 },
          { level: 1, start: 4, length: 3 },
          { level: 0, start: 7, length: 4 },
        ],
      )
    end

    it 'splits digit runs inside RTL text' do
      runs = described_class.visual_runs(
        "\u05D0\u05D112\u05D1",
        base_direction: :rtl,
      )
      expect(runs.map { |run| run[:level] }).to eq([1, 2, 1])
    end
  end
end
