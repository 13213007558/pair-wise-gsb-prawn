# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Text::Vertical::Box do
  let(:pdf) { create_pdf }
  let(:font_path) { "#{Prawn::DATADIR}/fonts/gkai00mp.ttf" }

  # gkai00mp.ttf at 12pt:
  #   vertical advance: 12.0
  #   vertical origin: [6.0, 10.546875] for full-width glyphs,
  #                    [3.0, 10.546875] for Latin letters
  #   column pitch (font height): 12.924
  #   ascender: 10.536, descender: 1.452
  let(:pitch) { 12.924 }
  let(:origin_y) { 10.546875 }

  def positions_of(pdf)
    PDF::Inspector::Text.analyze(pdf.render).positions
  end

  describe 'basic layout' do
    it 'lays out glyphs top to bottom using vertical metrics' do
      pdf.font(font_path)
      pdf.vertical_text_box('中竖', at: [100, 700], width: 200, height: 100, size: 12)

      expect(positions_of(pdf)).to eq(
        [
          [287.538, 689.45312],
          [287.538, 677.45312],
        ],
      )
    end

    it 'reports used height and width' do
      pdf.font(font_path)
      box = described_class.new(
        [{ text: '中竖' }],
        document: pdf, at: [100, 700], width: 200, height: 100, size: 12,
      )
      box.render

      expect(box.height).to eq(24)
      expect(box.width).to eq(pitch)
      expect(box.text).to eq('中竖')
      expect(box.line_height).to eq(pitch)
      expect(box.everything_printed?).to be(true)
      expect(box.nothing_printed?).to be(false)
    end

    it 'starts a new column to the left of the previous one' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中竖排文',
        at: [100, 700], width: 200, height: 26, size: 12,
      )

      expect(positions_of(pdf)).to eq(
        [
          [287.538, 689.45312],
          [287.538, 677.45312],
          [274.614, 689.45312],
          [274.614, 677.45312],
        ],
      )
    end

    it 'spaces columns with leading' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中竖排文',
        at: [100, 700], width: 200, height: 26, size: 12, leading: 2,
      )

      expect(positions_of(pdf)).to eq(
        [
          [287.538, 689.45312],
          [287.538, 677.45312],
          [272.614, 689.45312],
          [272.614, 677.45312],
        ],
      )
    end

    it 'breaks columns on newlines' do
      pdf.font(font_path)
      box = described_class.new(
        [{ text: "中\n文" }],
        document: pdf, at: [100, 700], width: 200, height: 100, size: 12,
      )
      box.render

      expect(positions_of(pdf)).to eq(
        [
          [287.538, 689.45312],
          [274.614, 689.45312],
        ],
      )
      expect(box.text).to eq("中\n文")
    end

    it 'uses the font vertical metrics of each fragment' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        [{ text: '中', size: 24 }, { text: '文' }],
        at: [100, 700], width: 200, height: 100, size: 12,
      )

      expect(positions_of(pdf)).to eq(
        [
          [275.076, 678.90625],
          [281.076, 665.45312],
        ],
      )
    end

    it 'applies character spacing to the vertical advance' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中竖',
        at: [100, 700], width: 200, height: 100, size: 12,
        character_spacing: 2,
      )

      expect(positions_of(pdf)).to eq(
        [
          [287.538, 689.45312],
          [287.538, 675.45312],
        ],
      )
    end

    it 'handles empty text' do
      pdf.font(font_path)
      box = described_class.new(
        [{ text: '' }],
        document: pdf, at: [100, 700], width: 200, height: 100, size: 12,
      )

      expect { box.render }.to_not raise_error
      expect(box.nothing_printed?).to be(true)
      expect(box.everything_printed?).to be(true)
    end
  end

  describe 'alignment' do
    it 'aligns the text block horizontally' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中',
        at: [100, 700], width: 200, height: 100, size: 12, align: :left,
      )

      expect(positions_of(pdf)).to eq([[100.462, 689.45312]])
    end

    it 'centers the text block horizontally' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中',
        at: [100, 700], width: 200, height: 100, size: 12, align: :center,
      )

      expect(positions_of(pdf)).to eq([[194.0, 689.45312]])
    end

    it 'aligns the text block vertically' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中',
        at: [100, 700], width: 200, height: 100, size: 12, valign: :bottom,
      )

      expect(positions_of(pdf)).to eq([[287.538, 601.45312]])
    end

    it 'centers the text block vertically' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中',
        at: [100, 700], width: 200, height: 100, size: 12, valign: :center,
      )

      expect(positions_of(pdf)).to eq([[287.538, 645.45312]])
    end
  end

  describe 'Latin rule' do
    let(:tm_inspector) do
      Class.new(PDF::Inspector) do
        attr_reader :matrices

        def initialize
          super
          @matrices = []
        end

        def set_text_matrix_and_text_line_matrix(*args)
          @matrices << args
        end
      end
    end

    it 'rotates Latin runs 90 degrees clockwise by default' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中AB文',
        at: [100, 700], width: 200, height: 100, size: 12,
      )

      analysis = tm_inspector.analyze(pdf.render)
      expect(analysis.matrices.length).to eq(1)
      matrix = analysis.matrices.first
      expect(matrix[0, 4]).to eq([0.0, -1.0, 1.0, 0.0])
      expect(matrix[4]).to be_within(0.001).of(288.996)
      expect(matrix[5]).to be_within(0.001).of(688.0)
    end

    it 'advances the column by the width of the rotated run' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中AB文',
        at: [100, 700], width: 200, height: 100, size: 12,
      )

      positions = positions_of(pdf)
      # 文 follows the rotated run: 12 (中) + 12 (AB at 6pt per letter)
      expect(positions.last[0]).to be_within(0.001).of(287.538)
      expect(positions.last[1]).to be_within(0.001).of(665.453125)
    end

    it 'sets Latin letters upright with vertical metrics when declared' do
      pdf.vertical_latin_rule = :upright
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中A文',
        at: [100, 700], width: 200, height: 100, size: 12,
      )

      expect(positions_of(pdf)).to eq(
        [
          [287.538, 689.45312],
          [290.538, 677.45312],
          [287.538, 665.45312],
        ],
      )
    end

    it 'moves a run that does not fit to the next column' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中AB',
        at: [100, 700], width: 200, height: 20, size: 12,
      )

      expect(positions_of(pdf).first).to eq([287.538, 689.45312])

      analysis = tm_inspector.analyze(pdf.render)
      expect(analysis.matrices.first[4]).to be_within(0.001).of(276.072)
      expect(analysis.matrices.first[5]).to be_within(0.001).of(700.0)
    end

    it 'can be overridden per box' do
      pdf.vertical_latin_rule = :upright
      pdf.font(font_path)
      pdf.vertical_text_box(
        '中A文',
        at: [100, 700], width: 200, height: 100, size: 12,
        latin_rule: :rotate,
      )

      analysis = tm_inspector.analyze(pdf.render)
      expect(analysis.matrices.length).to eq(1)
    end

    it 'rejects invalid rules' do
      expect { pdf.vertical_latin_rule = :sideways }
        .to raise_error(ArgumentError, /latin_rule/)
    end
  end

  describe 'overflow' do
    it 'truncates text that does not fit and returns it' do
      pdf.font(font_path)
      unprinted = pdf.vertical_text_box(
        '中竖排文本列',
        at: [100, 700], width: 30, height: 26, size: 12,
      )

      expect(unprinted).to eq([{ text: '本列' }])
      expect(positions_of(pdf).length).to eq(4)
    end

    it 'reports the printed state' do
      pdf.font(font_path)
      box = described_class.new(
        [{ text: '中竖排文本列' }],
        document: pdf, at: [100, 700], width: 30, height: 26, size: 12,
      )
      box.render

      expect(box.everything_printed?).to be(false)
      expect(box.nothing_printed?).to be(false)
      expect(box.text).to eq("中竖\n排文")
    end

    it 'returns all text when no glyph fits the column height' do
      pdf.font(font_path)
      box = described_class.new(
        [{ text: '中竖' }],
        document: pdf, at: [100, 700], width: 30, height: 5, size: 12,
      )
      unprinted = box.render

      expect(unprinted).to eq([{ text: '中竖' }])
      expect(box.nothing_printed?).to be(true)
    end

    it 'expands towards the frame edge with :expand' do
      pdf.font(font_path)
      unprinted = pdf.vertical_text_box(
        '中竖排文本列',
        at: [100, 700], width: 30, height: 26, size: 12,
        overflow: :expand,
      )

      expect(unprinted).to eq([])
      expect(positions_of(pdf).length).to eq(6)
    end

    it 'shrinks the font size with :shrink_to_fit' do
      pdf.font(font_path)
      unprinted = pdf.vertical_text_box(
        '中竖排文本列溢出测试',
        at: [100, 700], width: 30, height: 40, size: 12,
        overflow: :shrink_to_fit,
      )

      expect(unprinted).to eq([])
      text = PDF::Inspector::Text.analyze(pdf.render)
      expect(text.font_settings.map { |f| f[:size] }.uniq).to eq([9])
    end

    it 'raises CannotFit when no column fits the box width' do
      pdf.font(font_path)
      expect do
        pdf.vertical_text_box(
          '中',
          at: [100, 700], width: 10, height: 100, size: 12,
        )
      end.to raise_error(Prawn::Errors::CannotFit)
    end
  end

  describe 'links' do
    it 'creates a link annotation covering the vertical fragment' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        [{ text: '链接', link: 'http://example.com' }],
        at: [100, 700], width: 100, height: 100, size: 12,
      )

      reader = PDF::Reader.new(StringIO.new(pdf.render))
      annots = reader.page(1).attributes[:Annots]
      expect(annots.length).to eq(1)

      annot = reader.objects[annots.first]
      expect(annot[:A][:URI]).to eq('http://example.com')
      expect(annot[:Rect][0]).to be_within(0.001).of(187.076)
      expect(annot[:Rect][1]).to be_within(0.001).of(676.0)
      expect(annot[:Rect][2]).to be_within(0.001).of(200.0)
      expect(annot[:Rect][3]).to be_within(0.001).of(700.0)
    end

    it 'creates one annotation per column for fragments spanning columns' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        [{ text: '链接文字', link: 'http://example.com' }],
        at: [100, 700], width: 100, height: 26, size: 12,
      )

      reader = PDF::Reader.new(StringIO.new(pdf.render))
      annots = reader.page(1).attributes[:Annots]
      expect(annots.length).to eq(2)

      rects = annots.map { |a| reader.objects[a][:Rect] }
      expect(rects[0][0]).to be_within(0.001).of(187.076)
      expect(rects[1][0]).to be_within(0.001).of(174.152)
      expect(rects[1][2]).to be_within(0.001).of(187.076)
    end

    it 'supports inline formatted links' do
      pdf.font(font_path)
      pdf.vertical_text_box(
        "中<link href='http://example.com'>文</link>",
        at: [100, 700], width: 100, height: 100, size: 12,
        inline_format: true,
      )

      reader = PDF::Reader.new(StringIO.new(pdf.render))
      annots = reader.page(1).attributes[:Annots]
      expect(annots.length).to eq(1)
      expect(reader.objects[annots.first][:A][:URI])
        .to eq('http://example.com')
    end
  end

  describe 'font requirements' do
    it 'raises a meaningful error for built-in fonts' do
      expect do
        pdf.vertical_text_box('hello', at: [100, 700], width: 100, height: 100)
      end.to raise_error(
        Prawn::Errors::UnsupportedVerticalFont,
        /vhea\/vmtx.*Helvetica/,
      )
    end

    it 'raises a meaningful error for fonts without vertical metrics' do
      pdf.font("#{Prawn::DATADIR}/fonts/DejaVuSans.ttf")
      expect do
        pdf.vertical_text_box('hello', at: [100, 700], width: 100, height: 100)
      end.to raise_error(
        Prawn::Errors::UnsupportedVerticalFont,
        /vhea\/vmtx.*DejaVuSans/,
      )
    end
  end

  describe 'vertical glyph substitution' do
    # gkai00mp.ttf extended with a GSUB table designating vertical
    # variants: （ U+FF08 -> 「, ） U+FF09 -> 」, ， U+FF0C -> 、
    let(:gsub_font_path) do
      @gsub_font_path ||= font_with_extra_table(
        font_path,
        'GSUB',
        build_gsub_table(
          substitutions: { 417 => 721, 418 => 722, 421 => 713 },
        ),
      )
    end

    let(:gsub_font) { pdf.find_font(gsub_font_path) }

    it 'picks the vertical variants designated by the font' do
      pdf.font(gsub_font_path)
      font = gsub_font

      expect(font.vertical_substitutions?).to be(true)
      expect(font.vertical_substitute_for(0xFF08)).to eq(721)
      expect(font.vertical_substitute_for(0xFF09)).to eq(722)
      expect(font.vertical_substitute_for(0xFF0C)).to eq(713)
      expect(font.vertical_substitute_for(0x4E2D)).to be_nil
      expect(font.vertical_glyph_for(0xFF08)).to eq(721)
      expect(font.vertical_glyph_for(0x4E2D)).to eq(980)
    end

    it 'renders brackets and commas with their vertical variants' do
      pdf.font(gsub_font_path)
      pdf.vertical_text_box(
        '（中），',
        at: [100, 700], width: 200, height: 100, size: 12,
      )
      pdf.render

      subsets = gsub_font.instance_variable_get(:@subsets)
      vertical_subset =
        (0..3).map { |i| subsets[i] }
          .find { |s| s.is_a?(Prawn::Fonts::VerticalGlyphSubset) }

      expect(vertical_subset).to_not be_nil
      charmap = vertical_subset.new_cmap_table[:charmap]
      substituted =
        charmap.reject { |code, _| code == 0x20 }
          .transform_values { |ids| ids[:old] }
      expect(substituted.values).to contain_exactly(721, 722, 713)

      # the original characters stay extractable
      expect(vertical_subset.to_unicode_map.values)
        .to include(0xFF08, 0xFF09, 0xFF0C)
    end

    it 'positions substituted glyphs with their vertical metrics' do
      pdf.font(gsub_font_path)
      pdf.vertical_text_box(
        '（中），。',
        at: [100, 700], width: 200, height: 100, size: 12,
      )

      expect(positions_of(pdf)).to eq(
        [
          [287.538, 689.45312],
          [287.538, 677.45312],
          [287.538, 665.45312],
          [287.538, 653.45312],
          [287.538, 641.45312],
        ],
      )
    end

    it 'keeps the original characters extractable from the document' do
      pdf.font(gsub_font_path)
      pdf.vertical_text_box(
        '（中），',
        at: [100, 700], width: 200, height: 100, size: 12,
      )

      reader = PDF::Reader.new(StringIO.new(pdf.render))
      expect(reader.page(1).text).to eq("（\n中\n）\n，")
    end

    it 'renders substituted glyphs with full font embedding' do
      pdf.font_families['KaiVert'] = {
        normal: { file: gsub_font_path, subset: false },
      }
      pdf.font('KaiVert')
      pdf.vertical_text_box(
        '（中）',
        at: [100, 700], width: 200, height: 100, size: 12,
      )

      reader = PDF::Reader.new(StringIO.new(pdf.render))
      content = reader.page(1).raw_content
      # glyph IDs 721, 980, 722 in the content stream
      expect(content).to include('<02d1>')
      expect(content).to include('<03d4>')
      expect(content).to include('<02d2>')
    end
  end

  describe 'dry run' do
    it 'computes the layout without drawing anything' do
      pdf.font(font_path)
      box = described_class.new(
        [{ text: '中竖排文本' }],
        document: pdf, at: [100, 700], width: 30, height: 26, size: 12,
      )
      unprinted = box.render(dry_run: true)

      expect(unprinted).to eq([{ text: '本' }])
      expect(box.height).to eq(24)
      expect(PDF::Inspector::Text.analyze(pdf.render).strings).to be_empty
    end
  end
end
