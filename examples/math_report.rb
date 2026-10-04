# frozen_string_literal: true

# Demo for Prawn::Math: renders one page of multi-level nested formulas
# with every box's bounding frame and baseline drawn for inspection,
# plus a metrics table on the page and a JSON manifest
# (math_report_boxes.json) so all positions can be verified
# independently.
#
# Run from the repository root:
#   bundle exec ruby examples/math_report.rb
#
# Outputs (repository root):
#   math_report.pdf        one page, formulas + box/baseline overlays
#   math_report_boxes.json per-box id, kind, baseline, bounds

require 'json'
require_relative '../lib/prawn'

OUT_PDF = File.expand_path(File.join(__dir__, '..', 'math_report.pdf'))
OUT_JSON = File.expand_path(File.join(__dir__, '..', 'math_report_boxes.json'))

FORMULAS = [
  {
    id: 'F1',
    title: 'quadratic formula (display, sqrt over full radicand)',
    size: 16,
    baseline: 648,
    expr: [:row, 'x', '=',
           [:frac,
            [:row, :minus, 'b', :pm,
             [:sqrt, [:row, [:sup, 'b', '2'], :minus, '4', 'a', 'c']]],
            [:row, '2', 'a']]],
  },
  {
    id: 'F2',
    title: 'continued fraction (nested fracs never cross the rules)',
    size: 16,
    baseline: 528,
    expr: [:frac, '1',
           [:row, '1', '+',
            [:frac, '1',
             [:row, '1', '+',
              [:frac, '1',
               [:row, '1', '+', 'x']]]]]],
  },
  {
    id: 'F3',
    title: 'sum with limits above/below (display big operator)',
    size: 16,
    baseline: 408,
    expr: [:row,
           [:bigop, :sum, [:row, 'i', '=', '1'], 'n'],
           [:sup, 'i', '2'], '=',
           [:frac,
            [:row, 'n', '(', 'n', '+', '1', ')', '(', '2', 'n', '+', '1', ')'],
            '6']],
  },
  {
    id: 'F4',
    title: 'integral with limits, scripts and nested sqrt/frac',
    size: 16,
    baseline: 296,
    expr: [:row,
           [:bigop, :int, '0', :infty],
           [:sup, 'e', [:row, :minus, [:sup, 'x', '2']]],
           'd', 'x', '=',
           [:frac, [:sqrt, :pi], '2']],
  },
].freeze

def round2(value)
  value.is_a?(Array) ? value.map { |v| round2(v) } : value.round(2)
end

def box_entry(id, box, x, baseline)
  {
    id: id,
    kind: box.kind.to_s,
    label: box.label,
    x: round2(x),
    baseline: round2(baseline),
    width: round2(box.width),
    height: round2(box.height),
    depth: round2(box.depth),
    bounds: round2(box.bounds_at(x, baseline)),
  }
end

pdf = Prawn::Document.new(page_size: 'LETTER', margin: 0)
Prawn::Math.install_fonts(pdf)

manifest = {
  coordinate_system: 'PDF points; origin at the bottom-left of the page',
  fonts: { Prawn::Math::FONT_FAMILY => Prawn::Math::FONT_FILES },
  formulas: [],
}
table_rows = []

pdf.canvas do
  pdf.fill_color '000000'
  pdf.font('Helvetica', size: 14, style: :bold) do
    pdf.draw_text('Prawn::Math - declarative math typesetting', at: [36, 762])
  end
  pdf.font('Helvetica', size: 6.5) do
    pdf.draw_text(
      'Fonts: DejaVu Sans regular/bold (PrawnMath family). ' \
      'Symbols: Greek letters, common operators/relations, big operators ' \
      'sum/prod/int (see Prawn::Math::SYMBOLS). Radicals are vector-drawn.',
      at: [36, 748],
    )
    pdf.draw_text(
      'Every box: dashed blue frame = bounds (width x height+depth), ' \
      'red dashed line = baseline. All coordinates in PDF points from ' \
      'the bottom-left of the page; full data in math_report_boxes.json.',
      at: [36, 739],
    )
  end

  # --- Inline demo: formula embedded in ordinary text on one baseline ---
  inline_boxes = []
  pdf.font('Helvetica', size: 10) do
    y = 712
    x = 36
    pdf.draw_text('Inline:', at: [x, y])
    x += pdf.width_of('Inline: ')
    box = pdf.math([:row, 'E', '=', 'm', [:sup, 'c', '2']],
                   at: [x, y], size: 10, display: false)
    box.each_box(x, y).with_index(1) do |(b, bx, by), i|
      inline_boxes << box_entry(format('F0.%02d', i), b, bx, by)
    end
    x += box.width
    pdf.draw_text(' and ', at: [x, y])
    x += pdf.width_of(' and ')
    box2 = pdf.math([:row, [:bigop, :sum, [:row, 'i', '=', '1'], 'n'], 'i'],
                    at: [x, y], size: 10, display: false)
    box2.each_box(x, y).with_index(inline_boxes.length + 1) do |(b, bx, by), i|
      inline_boxes << box_entry(format('F0.%02d', i), b, bx, by)
    end
    x += box2.width
    pdf.draw_text(' end.', at: [x, y])
    pdf.draw_text(
      "(root boxes: w=#{box.width.round(1)}/h=#{box.height.round(1)}" \
      "/d=#{box.depth.round(1)} and w=#{box2.width.round(1)}" \
      "/h=#{box2.height.round(1)}/d=#{box2.depth.round(1)})",
      at: [x + pdf.width_of(' end. '), y],
    )
  end
  manifest[:formulas] << {
    id: 'F0',
    title: 'inline embedding: E = mc^2 and an inline sum on the text baseline',
    baseline: 712,
    boxes: inline_boxes,
  }
  table_rows << ['F0 inline: E=mc^2, sum_{i=1}^n i (baseline y=712)']
  inline_boxes.each do |e|
    table_rows << [
      format('%s %-7s x=%.1f y=%.1f w=%.1f h=%.1f d=%.1f',
             e[:id], e[:kind], e[:x], e[:baseline],
             e[:width], e[:height], e[:depth]),
    ]
  end

  # --- Display formulas with per-box overlays ---
  FORMULAS.each do |spec|
    x = 250
    y = spec[:baseline]
    box = pdf.math(spec[:expr], at: [x, y], size: spec[:size], display: true)

    entries = []
    box.each_box(x, y).with_index(1) do |(b, bx, by), i|
      entries << box_entry(format('%s.%02d', spec[:id], i), b, bx, by)
    end
    manifest[:formulas] << {
      id: spec[:id],
      title: spec[:title],
      baseline: y,
      root: box_entry(spec[:id], box, x, y),
      boxes: entries,
    }

    # overlays: bounds + baselines for every box
    pdf.save_graphics_state do
      pdf.line_width = 0.3
      pdf.dash(1, space: 1)
      box.each_box(x, y) do |b, bx, by|
        pdf.stroke_color '7AA3CC'
        pdf.stroke_rectangle([bx, by - b.depth], b.width, b.height + b.depth)
        pdf.stroke_color 'CC4444'
        pdf.stroke_line([bx, by], [bx + b.width, by])
      end
    end

    pdf.fill_color '000000'
    pdf.font('Helvetica', size: 7) do
      pdf.draw_text(spec[:id], at: [36, y])
      pdf.draw_text(spec[:title], at: [36, y - 8])
      pdf.draw_text(
        format('root: x=%.1f baseline=%.1f w=%.2f h=%.2f d=%.2f',
               x, y, box.width, box.height, box.depth),
        at: [36, y - 16],
      )
    end

    table_rows << [
      format('%s %s (baseline y=%d)', spec[:id], spec[:title], y),
    ]
    entries.each do |e|
      table_rows << [
        format('%s %-7s x=%.1f y=%.1f w=%.1f h=%.1f d=%.1f',
               e[:id], e[:kind], e[:x], e[:baseline],
               e[:width], e[:height], e[:depth]),
      ]
    end
  end

  # --- Metrics table (abridged on the page; complete in the JSON) ---
  columns = [36, 226, 416]
  col = 0
  row_y = 268
  pdf.fill_color '000000'
  pdf.font('Helvetica', size: 4.5, style: :bold) do
    pdf.draw_text('Box metrics (id kind x baseline width height depth)',
                  at: [columns[0], row_y])
  end
  row_y -= 6
  pdf.font('Helvetica', size: 4.5) do
    table_rows.each do |(line)|
      if row_y < 20
        col += 1
        break if col >= columns.length

        row_y = 262
      end
      pdf.draw_text(line, at: [columns[col], row_y])
      row_y -= 5.2
    end
  end
end

pdf.render_file(OUT_PDF)
File.write(OUT_JSON, JSON.pretty_generate(manifest))
puts "wrote #{OUT_PDF}"
puts "wrote #{OUT_JSON} (#{manifest[:formulas].sum { |f| f[:boxes].length }} boxes)"
