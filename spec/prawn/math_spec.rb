# frozen_string_literal: true

require 'stringio'

require 'spec_helper'

describe Prawn::Formula do
  let(:pdf) { create_pdf }

  def find(box, type)
    box.flat.find { |child| child.type == type }
  end

  def find_by_id(box, id)
    box.flat.find { |child| child.id == id }
  end

  describe '#math_layout' do
    it 'measures inline runs from the shared text baseline' do
      box = pdf.math_layout(%w[a b], size: 12)

      expect(box.type).to eq(:row)
      expect(box.children.map(&:y)).to eq([0.0, 0.0])
      expect(box.children[1].x).to be_within(0.01).of(
        box.children[0].width
      )
      expect(box.width).to be_within(0.01).of(
        box.children.sum(&:width)
      )
    end

    it 'separates nested fraction rows from the fraction bar' do
      box = pdf.math_layout(
        {
          id: 'outer',
          frac: [
            { id: 'num', frac: %w[a b] },
            { id: 'den', frac: %w[c d] },
          ],
        },
        size: 20,
      )
      bar_y = box.details[:axis_y]
      thickness = box.details[:bar_thickness]
      numerator = find_by_id(box, 'num')
      denominator = find_by_id(box, 'den')

      expect(numerator.y - numerator.depth).to be >=(
        bar_y + thickness / 2.0
      )
      expect(denominator.y + denominator.height).to be <=(
        bar_y - thickness / 2.0
      )
      inner_numerator = find(numerator, :fraction)
      inner_denominator = find(denominator, :fraction)
      expect(inner_numerator.y - inner_numerator.depth).to be >=(
        numerator.details[:axis_y] + numerator.details[:bar_thickness] / 2.0
      )
      expect(
        inner_denominator.y + inner_denominator.height
      ).to be <=(
        inner_denominator.details[:axis_y] -
          inner_denominator.details[:bar_thickness] / 2.0
      )
    end

    it 'places the radical overbar beyond the complete radicand' do
      box = pdf.math_layout({ sqrt: 'abc' }, size: 18)
      radicand = box.children.first

      expect(radicand.x).to be > box.details[:radical_tip][0]
      expect(box.details[:overbar_left]).to be <= radicand.x + 0.01
      expect(box.details[:overbar_right]).to be >=(
        radicand.x + radicand.width
      )
      expect(box.details[:overbar_y]).to be >=(
        radicand.y + radicand.height
      )
      expect(box.details[:radical_foot][1]).to be <=(
        radicand.y - radicand.depth
      )
    end

    it 'positions superscripts and subscripts beside their bases' do
      sup = pdf.math_layout({ id: 's', sup: %w[x 2] }, size: 16)
      sub = pdf.math_layout({ id: 'b', sub: %w[j 1] }, size: 16)

      expect(sup.children[1].x).to be_within(0.01).of(
        sup.children[0].width
      )
      expect(sup.children[1].y).to be > 0
      expect(sub.children[1].x).to be_within(0.01).of(
        sub.children[0].width
      )
      expect(sub.children[1].y).to be < 0
    end

    it 'accepts product and integral operator shorthand symbols' do
      product = pdf.math_layout(:product, size: 16)
      integral = pdf.math_layout(:integral, size: 16)

      expect(product.details[:operator]).to eq(:product)
      expect(integral.details[:operator]).to eq(:integral)
      expect(product.width).to be_positive
      expect(integral.width).to be_positive
    end

    it 'accepts long-form fraction, radicand, and script keys' do
      box = pdf.math_layout(
        {
          numerator: { radicand: { base: 'x', sup: '2' } },
          denominator: 'y',
        },
        size: 14,
      )

      expect(box.type).to eq(:fraction)
      expect(find(box, :sqrt)).not_to be_nil
      expect(find(box, :sup)).not_to be_nil
    end

    it 'centers upper and lower limits on a large operator' do
      box = pdf.math_layout(
        { op: :sum, upper: 'n', lower: 'k=1' },
        size: 18,
      )
      glyph, upper, lower = box.children

      expect(upper.y).to be > glyph.y + glyph.height
      expect(lower.y + lower.height).to be < glyph.y - glyph.depth
      [upper, lower].each do |limit|
        expect(limit.x + limit.width / 2.0).to be_within(0.01).of(
          glyph.x + glyph.width / 2.0
        )
      end
    end

    it 'rejects glyphs missing from the selected font' do
      expect {
        pdf.math_layout('字', font: Prawn::Formula::DEFAULT_FONT_FAMILY)
      }.to raise_error(Prawn::Formula::UnsupportedGlyph)
    end

    it 'reports absolute and parent-relative boundaries' do
      box = pdf.math_layout({ id: 'f', frac: %w[a b] }, size: 12)
      report = pdf.math_layout_report(box, at: [10, 20])
      fraction = report.first
      numerator = report[1]

      expect(fraction[:local][:left]).to eq(0.0)
      expect(fraction[:page][:left]).to eq(10.0)
      expect(fraction[:page][:baseline_y]).to eq(20.0)
      expect(numerator[:parent]).to eq(fraction[:id])
      expect(numerator[:page][:baseline_y]).to be_within(0.01).of(
        20.0 + numerator[:local][:baseline_y]
      )
    end
  end

  describe '#draw_math' do
    it 'draws text and vector rules instead of rasterizing the formula' do
      pdf.draw_math({ frac: %w[a b] }, at: [40, 700], size: 14)
      output = pdf.render
      text = PDF::Inspector::Text.analyze(output)
      lines = PDF::Inspector::Graphics::Line.analyze(output)

      expect(text.strings).to include('a', 'b')
      expect(lines.points).not_to be_empty
    end

    it 'does not place the formula in an image XObject' do
      pdf.draw_math({ frac: %w[a b] }, at: [40, 700], size: 14)
      reader = PDF::Reader.new(StringIO.new(pdf.render))

      expect(reader.pages.first.attributes.dig('Resources', 'XObject')).to(
        be_nil
      )
    end

    it 'can embed a premeasured box on a normal text baseline' do
      layout = pdf.math_layout('x', size: 14)
      pdf.draw_text('y', at: [10, 650], size: 14)
      pdf.draw_math(layout, at: [20, 650])

      text = PDF::Inspector::Text.analyze(pdf.render)
      expect(text.strings).to eq(%w[y x])
    end
  end
end
