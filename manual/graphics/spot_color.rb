# frozen_string_literal: true

require 'prawn/manual_builder'

Prawn::ManualBuilder::Chapter.new do
  title 'Spot Colors'

  text do
    prose <<~TEXT
      For print production, colors can be kept as independent channels
      (spot colors) instead of being flattened to CMYK. Declaring a spot
      color with a single colorant name creates a <code>/Separation</code>
      color space, declaring it with multiple names creates a
      <code>/DeviceN</code> color space. Both need an alternate color used
      for preview and a tint transform mapping channel values to that
      alternate color.
    TEXT
  end

  example do
    pantone_red = declare_spot_color(
      'PANTONE 185 C',
      alternate: [0, 100, 93, 0],
    )
    pantone_blue = declare_spot_color(
      'PANTONE 300 C',
      alternate: [100, 56, 0, 18],
    )

    # Ask the renderer to overprint the two inks instead of knocking out.
    overprint_state = ref!(Type: :ExtGState, OP: true, op: true)
    page.resources[:ExtGState] ||= {}
    page.resources[:ExtGState][:GS1] = overprint_state
    renderer.add_content('/GS1 gs')

    fill_spot_color(pantone_red, 1)
    fill_circle([220, 500], 70)

    fill_spot_color(pantone_blue, 0.8)
    fill_circle([300, 500], 70)

    stroke_spot_color(pantone_blue, 1)
    fill_spot_color(pantone_red, 0.6)
    fill_and_stroke_rectangle([150, 250], 220, 80)

    fill_spot_color(pantone_blue, 1)
    draw_text('Two spot colors, overprinting', at: [150, 200])
  end
end
