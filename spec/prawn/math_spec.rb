# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Prawn::Math do
  let(:pdf) { create_pdf }

  def layout(expr, size: 12, display: true)
    pdf.math_box(expr, size: size, display: display)
  end

  # Walks a box tree placed at (x, baseline) and returns
  # [box, x, baseline] triples.
  def placed(box, x = 0.0, baseline = 0.0)
    box.each_box(x, baseline).to_a
  end

  describe 'supported fonts and symbols' do
    let(:cmap) do
      TTFunk::File.open(
        File.join(Prawn::DATADIR, 'fonts', Prawn::Math::FONT_FILES[:normal]),
      ).cmap.tables.first
    end

    it 'covers every named symbol in DejaVu Sans' do
      Prawn::Math::SYMBOLS.each_value do |glyph|
        expect(cmap[glyph.ord]).to be > 0
      end
    end

    it 'covers every big operator glyph in DejaVu Sans' do
      Prawn::Math::BIGOP_GLYPHS.each_value do |glyph|
        expect(cmap[glyph.ord]).to be > 0
      end
    end

    it 'registers the math font family on demand' do
      layout('x')
      expect(pdf.font_families).to have_key(Prawn::Math::FONT_FAMILY)
    end
  end

  describe 'text boxes' do
   it 'exposes width, height and depth from font metrics' do
     box = layout('x', size: 10)
     expect(box.width).to be > 0
      pdf.font(Prawn::Math::FONT_FAMILY, size: 10) do
        expect(box.height).to be_within(0.001).of(pdf.font.ascender)
        expect(box.depth).to be_within(0.001).of(pdf.font.descender)
        expect(box.width).to be_within(0.001).of(pdf.width_of('x'))
      end
    end

    it 'classifies relations and binary operators for spacing' do
      expect(described_class::TextBox.atom_for('=')).to eq(:rel)
      expect(described_class::TextBox.atom_for('+')).to eq(:bin)
      expect(described_class::TextBox.atom_for('x')).to eq(:ord)
    end
  end

  describe 'rows' do
    it 'lays out children left to right on a shared baseline' do
      box = layout([:row, 'a', 'b', 'c'])
      children = box.children
      expect(children.map { |_, _, dy| dy }).to all(eq(0.0))
      offsets = children.map { |_, dx, _| dx }
      expect(offsets).to eq(offsets.sort)
      expect(box.width).to be >=
        children.sum { |child, _, _| child.width }
    end

    it 'inserts glue around relations' do
      tight = layout([:row, 'a', 'b'])
      loose = layout([:row, 'a', '=', 'b'])
      sum = loose.children.sum { |child, _, _| child.width }
      expect(loose.width).to be > sum
      expect(tight.width).to eq(
        tight.children.sum { |child, _, _| child.width },
      )
    end
  end

  describe 'fractions' do
    it 'keeps numerator and denominator clear of the rule' do
      box = layout([:frac, 'a', 'b'])
      num, num_x, num_off = box.children[0]
      den, den_x, den_off = box.children[1]
      bar_top = box.axis + box.rule / 2.0
      bar_bottom = box.axis - box.rule / 2.0
      expect(num_off - num.depth).to be > bar_top
      expect(den_off + den.height).to be < bar_bottom
      expect(num_x).to be >= 0
      expect(den_x).to be >= 0
    end

    it 'never lets nested fractions cross any fraction rule' do
      expr = [:frac,
              [:frac, 'a', [:frac, 'b', 'c']],
              [:frac, [:frac, 'd', 'e'], 'f']]
      box = layout(expr)
      placed(box).each do |b, x, baseline|
        next unless b.is_a?(Prawn::Math::FracBox)

        b.children.each do |child, dx, dy|
          child_baseline = baseline + dy
          bar_top = baseline + b.axis + b.rule / 2.0
          bar_bottom = baseline + b.axis - b.rule / 2.0
          if dy.positive? # numerator sits above the rule
            expect(child_baseline - child.depth).to be > bar_top
          else # denominator sits below the rule
            expect(child_baseline + child.height).to be < bar_bottom
          end
        end
      end
    end

    it 'spans the widest of numerator and denominator' do
      box = layout([:frac, 'wide', 'w'])
      expect(box.width).to be >=
        [box.num.width, box.den.width].max
    end
  end

  describe 'square roots' do
    it 'covers the full radicand with the overline' do
      rad = layout([:frac, 'x', 'y'])
      box = layout([:sqrt, [:frac, 'x', 'y']])
      rad_x = box.children[0][1]
      # overline runs from the surd top to the right edge of the box,
      # past the radicand's right edge
      expect(box.width).to be > rad_x + rad.width
      # radicand top stays below the overline
      expect(box.height).to be > rad.height
      # radicand bottom stays above the surd's lowest point
      expect(box.depth).to be > rad.depth
    end

    it 'grows to cover nested radicals' do
      inner = layout([:sqrt, 'x'])
      outer = layout([:sqrt, [:sqrt, 'x']])
      expect(outer.height).to be > inner.height
      expect(outer.width).to be > inner.width
    end
  end

  describe 'scripts' do
    it 'raises superscripts and lowers subscripts' do
      box = layout([:subsup, 'x', '1', '2'])
      expect(box.sup_off).to be > 0
      expect(box.sub_off).to be > 0
      expect(box.height).to be >= box.sup_off + box.sup.height
      expect(box.depth).to be >= box.sub_off + box.sub.depth
    end

    it 'keeps a minimum gap between stacked scripts' do
      box = layout([:subsup, 'x', '1', '2'])
      sup_bottom = box.sup_off - box.sup.depth
      sub_top = box.sub.height - box.sub_off
      expect(sup_bottom - sub_top).to be > 0
    end

    it 'places scripts to the right of the base' do
      box = layout([:sup, 'x', '2'])
      _, sup_x, = box.children[1]
      expect(sup_x).to be > box.base.width
    end
  end

  describe 'big operators' do
    it 'stacks limits above and below in display style' do
      box = layout([:bigop, :sum, 'i', 'n'])
      expect(box.kind).to eq(:bigop)
      over = box.children.find { |child, _, _| child.equal?(box.over) }
      under = box.children.find { |child, _, _| child.equal?(box.under) }
      op = box.children.find { |child, _, _| child.equal?(box.op) }
      expect(over[2] - box.over.depth).to be > op[2] + box.op.height
      expect(under[2] + box.under.height).to be < op[2] - box.op.depth
    end

    it 'moves limits to the side in inline style' do
      box = layout([:bigop, :sum, 'i', 'n'], display: false)
      expect(box.kind).to eq(:scripts)
    end

    it 'rejects unknown operators' do
      expect { layout([:bigop, :nope, nil, nil]) }
        .to raise_error(ArgumentError)
    end
  end

  describe 'document integration' do
    it 'renders on a baseline and returns the root box' do
      box = pdf.math([:frac, 'x', '2'], at: [100, 500], size: 14)
      expect(box).to be_a(Prawn::Math::Box)
      text = PDF::Inspector::Text.analyze(pdf.render)
      expect(text.strings.join).to include('x')
    end

    it 'embeds inline with ordinary text on a shared baseline' do
      pdf.font('Helvetica', size: 12)
      pdf.draw_text('a = ', at: [50, 500])
      prefix = pdf.width_of('a = ')
      box = pdf.math([:sqrt, 'b'], at: [50 + prefix, 500], size: 12)
      pdf.draw_text(' done', at: [50 + prefix + box.width, 500])
      text = PDF::Inspector::Text.analyze(pdf.render)
      expect(text.strings.join).to include('done')
    end
  end
end
