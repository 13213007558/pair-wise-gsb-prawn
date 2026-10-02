# frozen_string_literal: true

require 'prawn/manual_builder'

Prawn::ManualBuilder::Chapter.new do
  title 'Spot Colors'

  text do
    prose <<~TEXT
      For print production, brand (spot) colors should not be flattened to
      RGB or CMYK values. Instead they can be declared as Separation (one
      colorant) or DeviceN (a mix of colorants) color spaces with an
      alternate color space and a tint transform that is only used for
      preview and on devices without the colorant.

      A tint transform can be a simple interpolation between the alternate
      colors at tint 0 and tint 1 (<code>c0</code>/<code>c1</code>), or an
      explicit PostScript calculator function for full control.
    TEXT
  end

  example do
    # Two spot colorants declared as Separation color spaces
    red = register_separation(
      'Brand Red',
      alternate: :DeviceCMYK,
      c1: [0, 100, 85, 5],
    )
    yellow = register_separation(
      'Brand Yellow',
      alternate: :DeviceCMYK,
      c1: [0, 25, 100, 0],
    )

    # A DeviceN color space mixing both colorants. The tint transform is a
    # PostScript calculator function mapping the two tints to CMYK.
    mix = register_device_n(
      ['Brand Red', 'Brand Yellow'],
      alternate: :DeviceCMYK,
      tint_transform: '{
        2 copy 0.25 mul add 3 1 roll
        exch dup 0.05 mul 3 1 roll 0.85 mul add
        exch 0 4 1 roll
      }',
    )

    fill_spot_color(red, 1)
    fill_circle([130, 600], 50)

    fill_spot_color(yellow, 0.8)
    fill_circle([280, 600], 50)

    # A 70%/70% mix of the two colorants
    fill_spot_color(mix, 0.7, 0.7)
    fill_circle([430, 600], 50)

    stroke_spot_color(mix, 1, 0.5)
    self.line_width = 5
    stroke_rectangle([130, 350], 300, 100)
  end
end
