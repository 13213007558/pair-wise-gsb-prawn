# frozen_string_literal: true

# Usage:
#   bundle exec ruby examples/math_nested_formula.rb
#
# Produces nested-math-formula.pdf and nested-math-formula.json in the
# working directory.

require 'json'
require_relative '../lib/prawn'

EXPRESSION = [
  { id: 'lead', text: 'y=' },
  {
    id: 'sum',
    label: 'summation',
    op: :sum,
    upper: { id: 'sum-upper', label: 'upper-limit', text: 'n' },
    lower: { id: 'sum-lower', label: 'lower-limit', text: 'k=1' },
  },
  { id: 'operator-gap', space: 0.25 },
  {
    id: 'main-fraction',
    label: 'main fraction',
    numerator: {
      id: 'x-squared',
      label: 'superscript',
      base: { id: 'x-base', text: 'x' },
      sup: { id: 'two-sup', text: '2' },
    },
    denominator: {
      id: 'outer-root',
      label: 'outer radical',
      sqrt: {
        id: 'rooted-fraction',
        label: 'rooted nested fraction',
        numerator: [
          { id: 'one-plus', text: '1+' },
          {
            id: 'small-fraction',
            label: 'small fraction',
            numerator: { id: 'small-num', text: 'b' },
            denominator: { id: 'small-den', text: 'c' },
          },
        ],
        denominator: {
          id: 'inner-root',
          label: 'inner radical',
          sqrt: { id: 'radical-sum', text: 'x+1' },
        },
      },
    },
  },
]

origin = [36, 485]
size = 15

Prawn::Document.generate(
  'nested-math-formula.pdf',
  page_size: 'A4',
  page_layout: :landscape,
  margin: 24,
) do |pdf|
  pdf.font('Helvetica')
  pdf.font_size(13)
  pdf.draw_text(
    'Declarative Prawn math typesetting: nested fractions, radicals, scripts, and limits',
    at: [24, 555],
  )
  pdf.font_size(9)
  pdf.draw_text(
    'Default math font: embedded DejaVu Sans regular/bold. Supported node set: rows, text, frac, sqrt, sup/sub/script, op, and space.',
    at: [24, 540],
  )
  pdf.draw_text(
    'Formula glyphs are real PDF text; fraction bars and radicals are stroked vector paths. No formula image is embedded.',
    at: [24, 526],
  )

  layout = pdf.draw_math(EXPRESSION, at: origin, size: size)

  pdf.stroke_color = '999999'
  pdf.line_width(0.35)
  pdf.line(
    origin[0] - 8,
    430,
    origin[0] + layout.width + 8,
    430,
  )
  pdf.font_size(10)
  pdf.draw_text('Ordinary text baseline:', at: [24, 430])
  inline_layout = pdf.draw_math(
    { sqrt: { frac: %w[a+b c] } },
    at: [155, 430],
    size: 12,
  )
  pdf.stroke_color = '000000'

  pdf.font_size(11)
  pdf.draw_text('Measured root box:', at: [24, 405])
  pdf.draw_text(
    format(
      'width %.3f pt, height %.3f pt above baseline, depth %.3f pt below baseline',
      inline_layout.width,
      inline_layout.height,
      inline_layout.depth,
    ),
    at: [145, 405],
  )

  report = pdf.math_layout_report(layout, at: origin)
  columns = [
    [:id, 44, 'id'],
    [:type, 62, 'type'],
    [:parent, 54, 'parent'],
    [:x, 44, 'local x'],
    [:baseline_y, 50, 'local base'],
    [:width, 48, 'width'],
    [:height, 48, 'height'],
    [:depth, 48, 'depth'],
    [:left, 48, 'page left'],
    [:baseline_y, 56, 'page base'],
    [:right, 50, 'page right'],
    [:top, 48, 'page top'],
    [:bottom, 52, 'page bottom'],
    [:axis, 48, 'axis/bar y'],
    [:overbar, 52, 'overbar y'],
  ]

  table_left = 24
  table_top = 378
  row_height = 13
  x_positions = columns.each_with_object([]) do |(_, width, *_), positions|
    positions << (positions.last || table_left) + width
  end
  x_positions.unshift(table_left)

  pdf.font_size(7)
  columns.each_with_index do |(_, _, heading), index|
    pdf.draw_text(heading, at: [x_positions[index] + 2, table_top])
  end

  report.each_with_index do |row, row_index|
    y = table_top - ((row_index + 1) * row_height)
    values = [
      row[:id],
      row[:type],
      row[:parent],
      row[:local][:x],
      row[:local][:baseline_y],
      row[:local][:width],
      row[:local][:height],
      row[:local][:depth],
      row[:page][:left],
      row[:page][:baseline_y],
      row[:page][:right],
      row[:page][:top],
      row[:page][:bottom],
      row[:axis_y] ? row[:page][:baseline_y] + row[:axis_y] : nil,
      row[:overbar_y] ? row[:page][:baseline_y] + row[:overbar_y] : nil,
    ]
    values.each_with_index do |value, column_index|
      formatted = value.is_a?(Numeric) ? format('%.3f', value) : value.to_s
      pdf.draw_text(formatted, at: [x_positions[column_index] + 2, y])
    end
  end

  table_width = columns.sum { |_, width, _| width }
  table_bottom = table_top - ((report.size + 1) * row_height)
  pdf.line_width(0.25)
  (0..report.size + 1).each do |row_index|
    y = table_top + 4 - (row_index * row_height)
    pdf.line(table_left, y, table_left + table_width, y)
  end
  x_positions.each do |x|
    pdf.line(x, table_top + 4, x, table_bottom + 4)
  end
  pdf.line(
    table_left + table_width,
    table_top + 4,
    table_left + table_width,
    table_bottom + 4,
  )

  pdf.font_size(8)
  pdf.draw_text(
    'Coordinates are PDF points. Page y is measured upward from the page bottom; local y is measured upward from each box baseline.',
    at: [24, 26],
  )

  File.write(
    'nested-math-formula.json',
    JSON.pretty_generate(
      {
        origin: origin,
        size: size,
        root: {
          width: layout.width,
          height: layout.height,
          depth: layout.depth,
          font_family: layout.font_family,
        },
        boxes: report,
      },
    ),
  )
end
