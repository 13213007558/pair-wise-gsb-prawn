# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Fonts::VerticalMetrics do
  let(:gkai) { TTFunk::File.open("#{Prawn::DATADIR}/fonts/gkai00mp.ttf") }

  it 'is not available for fonts without vhea/vmtx tables' do
    dejavu = TTFunk::File.open("#{Prawn::DATADIR}/fonts/DejaVuSans.ttf")
    expect(described_class.for(dejavu)).to be_nil
  end

  context 'with a font containing vhea/vmtx tables' do
    subject(:metrics) { described_class.for(gkai) }

    it 'parses the vhea header' do
      expect(metrics.ascender).to eq(900)
      expect(metrics.descender).to eq(-123)
      expect(metrics.line_gap).to eq(6)
    end

    it 'parses vertical advances and top side bearings' do
      # 中 (U+4E2D), glyph 980
      expect(metrics.advance_height(980)).to eq(1024)
      expect(metrics.top_side_bearing(980)).to eq(36)

      # ， (U+FF0C), glyph 421
      expect(metrics.advance_height(421)).to eq(1024)
      expect(metrics.top_side_bearing(421)).to eq(599)

      # A (U+0041), glyph 65
      expect(metrics.advance_height(65)).to eq(1024)
      expect(metrics.top_side_bearing(65)).to eq(206)
    end
  end
end

describe Prawn::Fonts::TTF, 'vertical metrics' do
  let(:pdf) { create_pdf }
  let(:font) { pdf.find_font("#{Prawn::DATADIR}/fonts/gkai00mp.ttf") }
  let(:latin_font) { pdf.find_font("#{Prawn::DATADIR}/fonts/DejaVuSans.ttf") }

  it 'knows whether the font provides vertical metrics' do
    expect(font.vertical_metrics?).to be(true)
    expect(latin_font.vertical_metrics?).to be(false)
  end

  it 'knows whether the font designates vertical glyph variants' do
    expect(font.vertical_substitutions?).to be(false)
  end

  it 'provides vertical advances normalized to a 1000-unit em' do
    expect(font.vertical_advance_for(0x4E2D)).to eq(1000.0)
    expect(font.vertical_advance_for(0xFF0C)).to eq(1000.0)
  end

  it 'provides vertical origins normalized to a 1000-unit em' do
    # 中: half of the 1024-unit horizontal advance, vhea ascender
    expect(font.vertical_origin_for(0x4E2D)).to eq([500.0, 878.90625])
    # A: half of the 512-unit horizontal advance
    expect(font.vertical_origin_for(0x41)).to eq([250.0, 878.90625])
  end

  it 'uses the cmap glyph when the font designates no vertical variant' do
    expect(font.vertical_substitute_for(0xFF08)).to be_nil
    expect(font.vertical_glyph_for(0xFF08)).to eq(417)
  end

  it 'raises a meaningful error when vertical metrics are missing' do
    expect { latin_font.vertical_advance_for(0x41) }
      .to raise_error(Prawn::Fonts::TTF::NoVerticalMetrics, /vhea\/vmtx/)
    expect { latin_font.vertical_origin_for(0x41) }
      .to raise_error(Prawn::Fonts::TTF::NoVerticalMetrics, /vhea\/vmtx/)
  end
end
