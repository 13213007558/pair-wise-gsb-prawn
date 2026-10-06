# frozen_string_literal: true

require 'prawn'

output = ARGV.fetch(0, File.expand_path('spot_color_overprint.pdf', __dir__))

Prawn::Document.generate(output, page_size: [420, 260], margin: 24) do |pdf|
  gold = pdf.separation_color(
    'Gold Spot',
    :DeviceRGB,
    FunctionType: 2,
    C0: [1.0, 0.92, 0.55],
    C1: [0.87, 0.67, 0.0],
    N: 1.0,
  )
  blue = pdf.separation_color(
    'Blue Spot',
    :DeviceRGB,
    FunctionType: 2,
    C0: [0.72, 0.88, 1.0],
    C1: [0.0, 0.25, 0.82],
    N: 1.0,
  )

  pdf.overprint do
    pdf.fill_color(gold, 0.9)
    pdf.fill_circle([150, 130], 78)
    pdf.text('GOLD', size: 28, style: :bold)

    pdf.fill_color(blue, 0.9)
    pdf.fill_circle([250, 130], 78)

    pdf.stroke_color(blue, 1.0)
    pdf.line_width(4)
    pdf.stroke_rectangle([24, 24], 372, 212)
    pdf.text('BLUE', size: 28, style: :bold)
  end
end

puts "Wrote #{output}"
