# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Fonts::GPOS do
  # Builds a minimal GPOS table by hand covering:
  # * PairPos format 1 (coverage format 1)
  # * PairPos format 2 (coverage format 2, class defs formats 1 and 2)
  # * MarkToBase (coverage formats 1 and 2)
  # * script/language/feature selection
  #
  # Glyph IDs used: A=1, V=2, T=3, o=4, acute=5
  def build_gpos_table
    pair_pos2_subtable =
      [2, 24, 0x0004, 0, 34, 42, 2, 2].pack('n8') +
      [0, 0, 0, -50].pack('s>4') + # class matrix: [class1=1][class2=1] => -50
      [2, 1, 1, 1, 0].pack('n5') + # coverage format 2: glyphs 1..1 (A)
      [1, 1, 1, 1].pack('n4') +    # class def format 1: glyph 1 (A) => class 1
      [2, 1, 2, 2, 1].pack('n5')   # class def format 2: glyph 2 (V) => class 1

    pair_pos1_subtable =
      [1, 12, 0x0004, 0, 1, 18].pack('n6') +
      [1, 1, 3].pack('n3') +          # coverage format 1: glyph 3 (T)
      [1, 4].pack('n2') + [-30].pack('s>') # pair set: second glyph 4 (o) => -30

    mark_to_base_subtable =
      [1, 12, 18, 1, 28, 40].pack('n6') +
      [1, 1, 5].pack('n3') +          # mark coverage format 1: glyph 5 (acute)
      [2, 1, 1, 1, 0].pack('n5') +    # base coverage format 2: glyph 1 (A)
      [1, 0, 6].pack('n3') +          # mark array: class 0, anchor at +6
      [1, 100, 500].pack('n3') +      # mark anchor (100, 500)
      [1, 4].pack('n2') +             # base array: anchor at +4
      [1, 300, 700].pack('n3')        # base anchor (300, 700)

    lookups = [
      [2, pair_pos2_subtable],
      [2, pair_pos1_subtable],
      [4, mark_to_base_subtable],
    ]
    lookup_list = [lookups.length].pack('n')
    lookup_offset = 2 + (lookups.length * 2)
    lookups.each do |(type, subtable)|
      lookup_list << [lookup_offset].pack('n')
      lookup_offset += 8 + subtable.bytesize
    end
    lookups.each do |(type, subtable)|
      lookup_list << [type, 0, 1, 8].pack('n4') << subtable
    end

    feature_list =
      [3].pack('n') +
      ['kern', 'kern', 'mark'].each_with_index.map { |tag, i|
        "#{tag}#{[20 + (i * 6)].pack('n')}"
      }.join +
      [0, 1, 0].pack('n3') + # kern => lookup 0
      [0, 1, 1].pack('n3') + # kern (language-specific) => lookup 1
      [0, 1, 2].pack('n3')   # mark => lookup 2

    script_list =
      [2].pack('n') +
      "DFLT#{[14].pack('n')}" +
      "latn#{[26].pack('n')}" +
      [4, 0].pack('n2') +                 # DFLT script: default langsys at +4
      [0, 0xFFFF, 1, 0].pack('n4') +      #   langsys: feature 0 (kern)
      [10, 1].pack('n2') + "ENG #{[20].pack('n')}" + # latn script
      [0, 0xFFFF, 2, 0, 2].pack('n5') +   #   default langsys: kern + mark
      [0, 0xFFFF, 1, 1].pack('n4')        #   ENG langsys: language-specific kern

    header_size = 10
    script_offset = header_size
    feature_offset = script_offset + script_list.bytesize
    lookup_offset = feature_offset + feature_list.bytesize

    [1, 0, script_offset, feature_offset, lookup_offset].pack('n5') +
      script_list + feature_list + lookup_list
  end

  subject(:gpos) { described_class.new(build_gpos_table) }

  describe 'lookup selection' do
    it 'selects features of the DFLT script by default' do
      expect(gpos.lookup_indices).to eq([0])
    end

    it 'selects features of the requested script' do
      expect(gpos.lookup_indices(script: 'latn')).to eq([0, 2])
    end

    it 'selects features of the requested language system' do
      expect(gpos.lookup_indices(script: 'latn', language: 'ENG')).to eq([1])
    end

    it 'falls back to the default language system for unknown languages' do
      expect(gpos.lookup_indices(script: 'latn', language: 'FRA')).to eq([0, 2])
    end

    it 'returns no lookups for unknown scripts' do
      expect(gpos.lookup_indices(script: 'xxxx')).to eq([])
    end

    it 'filters by requested features' do
      expect(gpos.lookup_indices(script: 'latn', features: %w[mark])).to eq([2])
      expect(gpos.lookup_indices(script: 'latn', features: %w[kern mark])).to eq([0, 2])
      expect(gpos.lookup_indices(script: 'latn', features: %w[mark kern])).to eq([2, 0])
    end
  end

  describe 'positioning' do
    it 'applies PairPos format 2 (class-based) adjustments' do
      result = gpos.position([1, 2], [600, 620], script: 'latn')
      expect(result.map { |g| g[:advance] }).to eq([550, 620])
    end

    it 'applies PairPos format 1 (glyph pair) adjustments' do
      result = gpos.position([3, 4], [560, 500], script: 'latn', language: 'ENG')
      expect(result.map { |g| g[:advance] }).to eq([530, 500])
    end

    it 'attaches marks to base glyphs and zeroes their advance' do
      result = gpos.position([1, 5], [600, 240], script: 'latn')
      expect(result[1][:advance]).to eq(0)
      expect(result[1][:x_offset]).to eq(300 - 100 - 600)
      expect(result[1][:y_offset]).to eq(700 - 500)
    end

    it 'does not attach marks when the mark feature is not selected' do
      result = gpos.position([1, 5], [600, 240], script: 'latn', features: %w[kern])
      expect(result[1][:advance]).to eq(240)
      expect(result[1][:x_offset]).to eq(0)
    end

    it 'preserves the glyph-to-character correspondence' do
      result = gpos.position([1, 5, 2], [600, 240, 620], script: 'latn')
      expect(result.map { |g| g[:gid] }).to eq([1, 5, 2])
    end
  end

  describe 'with the GPOSTest fixture font' do
    let(:pdf) { create_pdf }
    let(:font_file) { "#{Prawn::DATADIR}/fonts/GPOSTest.ttf" }

    before { pdf.font(font_file) }

    it 'reports GPOS support' do
      expect(pdf.font.gpos?).to be(true)
      expect(pdf.font.gpos).to be_a(described_class)
    end

    it 'applies pair positioning to advances' do
      positioned = pdf.font.gpos_position_text('AV', true)
      expect(positioned.map { |g| g[:advance] }).to eq([520, 620])
      expect(positioned.map { |g| g[:codepoint] }).to eq([65, 86])
    end

    it 'applies class-based pair positioning' do
      positioned = pdf.font.gpos_position_text('To', true)
      expect(positioned.map { |g| g[:advance] }).to eq([520, 500])
    end

    it 'attaches combining marks to the base glyph without adding advance' do
      positioned = pdf.font.gpos_position_text("A\u0301", true)
      expect(positioned[1][:advance]).to eq(0)
      expect(positioned[1][:x_offset]).to eq(-420)
      expect(positioned[1][:y_offset]).to eq(220)
    end

    it 'stacks marks via mark-to-mark attachment' do
      positioned = pdf.font.gpos_position_text("A\u0301\u0307", true)
      expect(positioned[2][:advance]).to eq(0)
      expect(positioned[2][:x_offset]).to eq(-410)
      expect(positioned[2][:y_offset]).to eq(460)
    end

    it 'selects lookups by language system' do
      positioned = pdf.font.gpos_position_text('AV', script: 'latn', language: 'ENG')
      expect(positioned.map { |g| g[:advance] }).to eq([400, 620])
    end

    it 'selects lookups by feature' do
      positioned = pdf.font.gpos_position_text("A\u0301", features: %w[kern])
      expect(positioned[1][:advance]).to eq(240)
    end

    describe 'width computation' do
      it 'accounts for pair positioning' do
        expect(pdf.width_of('AV', gpos: true)).to eq(1140 * 12 / 1000.0)
        expect(pdf.width_of('AV')).to eq(1220 * 12 / 1000.0)
      end

      it 'does not count attached marks in the line width' do
        expect(pdf.width_of("A\u0301\u0307", gpos: true)).to eq(600 * 12 / 1000.0)
      end
    end

    describe 'rendering' do
      it 'emits pair adjustments as TJ kerning numbers' do
        pdf.text('AV', gpos: true)
        expect(pdf.render).to match(/\[<.*> 80 <.*>\] TJ/)
      end

      it 'emits mark offsets as TJ kerning numbers and text rise' do
        pdf.text("A\u0301\u0307", gpos: true)
        rendered = pdf.render
        expect(rendered).to match(/\[<.*> 420\] TJ/)
        expect(rendered).to match(/2\.64 Ts/)
        expect(rendered).to match(/5\.52 Ts/)
        expect(rendered).to match(/0(\.0)? Ts/)
      end

      it 'resets text rise after positioned marks' do
        pdf.text("A\u0301", gpos: true)
        pdf.text('plain')
        rendered = pdf.render
        expect(rendered.scan(/Ts$/).length).to be >= 2
      end
    end

    describe 'line wrapping' do
      let(:text) { 'To ' * 10 }

      it 'uses GPOS metrics for line breaking' do
        expect(pdf.width_of(text, gpos: true)).to be < pdf.width_of(text)
        expect(pdf.height_of(text, gpos: true, width: 153)).to eq(12)
        expect(pdf.height_of(text, width: 153)).to eq(24)
      end

      it 'wraps lines to the GPOS-computed width' do
        line_wrap = Prawn::Text::Formatted::LineWrap.new
        arranger = Prawn::Text::Formatted::Arranger.new(pdf, gpos: true)
        arranger.format_array = [{ text: 'AV AV' }]
        line_wrap.wrap_line(
          arranger: arranger,
          width: 1000,
          document: pdf,
          gpos: true,
        )
        expect(line_wrap.width).to eq((1140 + 250 + 1140) * 12 / 1000.0)
      end
    end

    describe 'encode_text' do
      it 'returns chunks with kerning numbers' do
        chunks = pdf.font.encode_text('AV', gpos: true)
        expect(chunks.length).to eq(1)
        (_subset, elements) = chunks.first
        expect(elements).to include(80)
      end
    end
  end

  describe 'with a real font (DejaVuSans)' do
    let(:pdf) { create_pdf }

    before { pdf.font("#{Prawn::DATADIR}/fonts/DejaVuSans.ttf") }

    it 'applies GPOS kerning from the latn script' do
      plain = pdf.width_of('AV')
      kerned = pdf.width_of('AV', gpos: { script: 'latn' })
      expect(kerned).to be < plain
      expect(kerned).to be_within(0.1).of(pdf.width_of('AV', kerning: true))
    end

    it 'attaches combining marks without adding width' do
      expect(pdf.width_of("A\u0301", gpos: { script: 'latn' }))
        .to be_within(0.01).of(pdf.width_of('A'))
    end
  end

  describe 'with fonts lacking a GPOS table' do
    let(:pdf) { create_pdf }

    it 'falls back to the regular width computation for TTF fonts' do
      pdf.font("#{Prawn::DATADIR}/fonts/gkai00mp.ttf")
      expect(pdf.font.gpos?).to be(false)
      expect(pdf.width_of('abc', gpos: true)).to eq(pdf.width_of('abc'))
    end

    it 'renders TTF text through the regular path' do
      pdf.font("#{Prawn::DATADIR}/fonts/gkai00mp.ttf")
      expect { pdf.text('abc', gpos: true) }.to_not raise_error
      expect(pdf.render).to_not match(/TJ/)
    end

    it 'ignores the option for AFM fonts' do
      pdf.font('Helvetica')
      expect { pdf.text('abc', gpos: true) }.to_not raise_error
      expect(pdf.width_of('abc', gpos: true)).to eq(pdf.width_of('abc'))
    end
  end
end
