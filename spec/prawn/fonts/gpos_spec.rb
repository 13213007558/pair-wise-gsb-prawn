# frozen_string_literal: true

require 'spec_helper'
require 'support/gpos_test_font'

RSpec.describe 'GPOS positioning' do
  let(:pdf) { create_pdf }
  let(:font) { pdf.find_font(GposTestFont.path) }
  let(:text) { "Toax\u0301\u0323" }
  let(:options) { { script: :default, language: :default, features: %i[kern mark mkmk] } }

  it 'positions pair and combining mark glyphs' do
    positions = font.send(:gpos_engine).apply(
      text.codepoints, font.send(:cmap), options,
    )

    expect(positions.map(&:x_advance).first(4)).to eq([1251, 1257, 1255, 1212])
    expect(positions[4]).to have_attributes(
      x_origin: 2508,
      x_placement: 490,
      y_placement: 680,
      x_advance: 0,
      attached_to: 2,
    )
    expect(positions[5]).to have_attributes(
      x_origin: 2508,
      x_placement: 1170,
      y_placement: 850,
      x_advance: 0,
      attached_to: 4,
    )
  end

  it 'measures line width with GPOS advances and zero-width marks' do
    expect(font.compute_width_of(text, size: 10, gpos: options)).to be_within(0.001).of(24.292)
  end

  it 'selects features by script and language' do
    positions = font.send(:gpos_engine).apply(
      text.codepoints, font.send(:cmap),
      options.merge(features: :kern),
    )

    expect(positions[1].x_advance).to eq(1257)
    expect(positions[4].x_advance).to eq(0)

    positions = font.send(:gpos_engine).apply(
      text.codepoints, font.send(:cmap),
      options.merge(features: %i[mark mkmk]),
    )

    expect(positions[1].x_advance).to eq(1253)
    expect(positions[4]).to have_attributes(x_advance: 0, attached_to: 2)
  end

  it 'ignores GPOS when the script or feature is not selected' do
    missing_script = options.merge(script: 'cyrl')
    positions = font.send(:gpos_engine).apply(
      text.codepoints, font.send(:cmap), missing_script,
    )

    expect(positions[1].x_advance).to eq(1253)
    expect(positions[4].x_advance).to eq(0)

    missing_feature = options.merge(features: :liga)
    positions = font.send(:gpos_engine).apply(
      text.codepoints, font.send(:cmap), missing_feature,
    )

    expect(positions[1].x_advance).to eq(1253)
    expect(positions[4]).to have_attributes(attached_to: nil)
  end

  it 'draws every glyph at GPOS coordinates' do
    pdf.font(GposTestFont.path)
    pdf.draw_text(text, at: [10, 20], size: 10, gpos: options)
    analysis = PDF::Inspector::Text.analyze(pdf.render)

    expect(analysis.strings.join).to eq(text)
    x = analysis.positions.map(&:first)
    y = analysis.positions.map(&:last)
    scale = 10.0 / 1000.0

    expected_x = [0, 1251, 2508, 3763, 2998, 3678].map {
      |origin| 10 + (origin * scale)
    }
    expected_y = [0, 0, 0, 0, -680, -850].map {
      |origin| 20 + (origin * scale)
    }
    x.zip(expected_x).each { |actual, expected| expect(actual).to be_within(0.001).of(expected) }
    y.zip(expected_y).each { |actual, expected| expect(actual).to be_within(0.001).of(expected) }
  end

  it 'uses GPOS width for formatted fragment measurement' do
    pdf.font(GposTestFont.path)
    box = Prawn::Text::Formatted::Box.new(
      [{ text: text }],
      document: pdf,
      at: [0, 100],
      width: 24,
      size: 10,
      disable_wrap_by_char: true,
      gpos: options,
    )
    expect { box.render(dry_run: true) }.to raise_error(Prawn::Errors::CannotFit)
  end

  it 'keeps the old path without a GPOS table' do
    plain = pdf.find_font("#{Prawn::DATADIR}/fonts/DejaVuSans.ttf")

    expect(plain.compute_width_of('To', size: 10)).to be_within(0.01).of(12.21)
    expect(plain.encode_text('To')).to eq([[0, 'To']])
  end

  it 'does not use GPOS unless requested' do
    expect(font.compute_width_of('To', size: 10, kerning: true)).to be_within(0.01).of(10.51)
    encoded = font.encode_text('To', kerning: true)

    expect(encoded.first[0]).to eq(0)
    expect(encoded.first[1]).to eq(['T', 169.921875, 'o'])
  end

  it 'positions glyphs with full font embedding' do
    full_font = pdf.find_font(GposTestFont.path, subset: false)
    encoded = full_font.encode_text(text, size: 10, gpos: options)

    expect(encoded.map { |_subset, run| run.encoded.bytesize }).to eq([text.length * 2])
    expect(encoded.first[1].positions.length).to eq(text.length)
  end
end
