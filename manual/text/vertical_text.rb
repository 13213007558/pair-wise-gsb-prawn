# frozen_string_literal: true

require 'prawn/manual_builder'

Prawn::ManualBuilder::Chapter.new do
  title 'Vertical (CJK) Text'

  text do
    prose <<~TEXT
      CJK text is traditionally written top to bottom, with columns
      running right to left. The <code>vertical_text_box</code> method
      typesets text this way, using the font's vertical metrics
      (<code>vhea</code>/<code>vmtx</code> tables) and the vertical glyph
      variants the font designates (GSUB <code>vert</code>/
      <code>vrt2</code> features), so brackets and punctuation are placed
      correctly.

      Only OpenType fonts that contain vertical metrics tables can be
      used. <code>Prawn::Errors::UnsupportedVerticalFont</code> is raised
      for any other font.

      Latin-script characters are handled according to the document-wide
      <code>vertical_latin_rule</code>: <code>:rotate</code> (the default)
      rotates Latin runs 90 degrees clockwise, while
      <code>:upright</code> sets them upright using vertical metrics. The
      rule can be overridden per box with the <code>:latin_rule</code>
      option.
    TEXT
  end

  example new_page: true do
    font("#{Prawn::ManualBuilder::DATADIR}/fonts/gkai00mp.ttf", size: 16) do
      vertical_text_box(
        '这是竖排文本，列从右往左排列。\n第二列从这里开始。',
        at: [bounds.right - 50, bounds.top - 50],
        width: 200,
        height: 300,
      )

      vertical_text_box(
        '括号（正确）和逗号，都使用竖排替代字形。',
        at: [bounds.right - 280, bounds.top - 50],
        width: 200,
        height: 300,
      )
    end
  end

  example do
    font("#{Prawn::ManualBuilder::DATADIR}/fonts/gkai00mp.ttf", size: 16) do
      # Latin runs are rotated 90 degrees clockwise by default
      vertical_text_box(
        '夹杂 Latin 字母的竖排文本。',
        at: [bounds.right - 50, bounds.top - 420],
        width: 200,
        height: 300,
      )

      # ...or set upright, like CJK characters
      vertical_text_box(
        '夹杂 Latin 字母的竖排文本。',
        at: [bounds.right - 280, bounds.top - 420],
        width: 200,
        height: 300,
        latin_rule: :upright,
      )
    end
  end
end
