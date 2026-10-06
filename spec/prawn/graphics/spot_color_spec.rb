# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Graphics::SpotColor do
  let(:pdf) { create_pdf }

  def analyze_color_spaces(document)
    reader = PDF::Reader.new(StringIO.new(document.render))
    spaces = reader.page(1).send(:resources).color_spaces
    spaces.to_h do |name, entry|
      definition = reader.objects.deref(entry)
      function = reader.objects.deref(definition[3])
      if function.is_a?(PDF::Reader::Stream)
        function = function.unfiltered_data
      end
      [name, { definition: definition, function: function }]
    end
  end

  let(:red) do
    pdf.declare_spot_color('PANTONE 185 C', alternate: [0, 100, 93, 0])
  end

  let(:blue) do
    pdf.declare_spot_color('PANTONE 300 C', alternate: [100, 56, 0, 18])
  end

  describe 'declare_spot_color' do
    it 'declares a Separation color space for a single colorant name' do
      pdf.fill_spot_color(red, 1)

      spaces = analyze_color_spaces(pdf).values
      expect(spaces.length).to eq(1)

      definition = spaces.first[:definition]
      expect(definition[0]).to eq(:Separation)
      expect(definition[1]).to eq(:'PANTONE 185 C')
      expect(definition[2]).to eq(:DeviceCMYK)
    end

    it 'defaults the tint transform to a linear interpolation from white' do
      pdf.fill_spot_color(red, 1)

      function = analyze_color_spaces(pdf).values.first[:function]
      expect(function[:FunctionType]).to eq(2)
      expect(function[:C0]).to eq([0, 0, 0, 0])
      expect(function[:C1].length).to eq(4)
      expect(function[:C1][1]).to be_within(0.001).of(1)
      expect(function[:N]).to eq(1)
    end

    it 'supports an RGB alternate color' do
      spot = pdf.declare_spot_color('Spot Red', alternate: 'e03226')
      pdf.fill_spot_color(spot, 1)

      space = analyze_color_spaces(pdf).values.first
      expect(space[:definition][2]).to eq(:DeviceRGB)
      expect(space[:function][:C0]).to eq([1, 1, 1])
      expect(space[:function][:C1][0]).to be_within(0.001).of(0.878)
    end

    it 'supports an explicit Type 2 tint transform' do
      spot = pdf.declare_spot_color(
        'PANTONE 300 C',
        alternate: [100, 56, 0, 18],
        tint_transform: { type: 2, c0: [0, 0, 0, 0], c1: [1, 0.56, 0, 0.18], n: 2 },
      )
      pdf.fill_spot_color(spot, 1)

      function = analyze_color_spaces(pdf).values.first[:function]
      expect(function[:FunctionType]).to eq(2)
      expect(function[:C1]).to eq([1, 0.56, 0, 0.18])
      expect(function[:N]).to eq(2)
    end

    it 'declares a DeviceN color space for multiple colorant names' do
      duo = pdf.declare_spot_color(
        ['PANTONE 185 C', 'PANTONE 300 C'],
        alternate: [0, 100, 93, 0],
        tint_transform: '{ 1 exch sub 0.93 mul exch 1 exch sub 0.56 mul 0 0.18 }',
      )
      pdf.fill_spot_color(duo, [0.5, 0.9])

      space = analyze_color_spaces(pdf).values.first
      definition = space[:definition]
      expect(definition[0]).to eq(:DeviceN)
      expect(definition[1]).to eq([:'PANTONE 185 C', :'PANTONE 300 C'])
      expect(definition[2]).to eq(:DeviceCMYK)
      expect(space[:function]).to eq(
        '{ 1 exch sub 0.93 mul exch 1 exch sub 0.56 mul 0 0.18 }',
      )
    end

    it 'reuses the resource for identical declarations' do
      first = pdf.declare_spot_color('PANTONE 185 C', alternate: [0, 100, 93, 0])
      second = pdf.declare_spot_color('PANTONE 185 C', alternate: [0, 100, 93, 0])

      expect(second).to equal(first)

      pdf.fill_spot_color(first, 1)
      expect(analyze_color_spaces(pdf).length).to eq(1)
    end

    it 'does not reuse the resource for same name with different transform' do
      first = pdf.declare_spot_color('PANTONE 185 C', alternate: [0, 100, 93, 0])
      second = pdf.declare_spot_color(
        'PANTONE 185 C',
        alternate: [0, 100, 93, 0],
        tint_transform: { type: 2, c0: [0, 0, 0, 0], c1: [0, 1, 0.93, 0], n: 2 },
      )

      expect(second).to_not eq(first)

      pdf.fill_spot_color(first, 1)
      pdf.fill_spot_color(second, 0.5)

      spaces = analyze_color_spaces(pdf).values
      expect(spaces.length).to eq(2)
      names = spaces.map { |space| space[:definition][1] }
      expect(names).to eq([:'PANTONE 185 C', :'PANTONE 185 C'])
      functions = spaces.map { |space| space[:function] }
      expect(functions.uniq.length).to eq(2)
    end

    it 'rejects declarations without colorant names' do
      expect { pdf.declare_spot_color([], alternate: [0, 100, 93, 0]) }
        .to raise_error(ArgumentError)
    end

    it 'rejects unsupported tint transforms' do
      expect {
        pdf.declare_spot_color(
          'PANTONE 185 C',
          alternate: [0, 100, 93, 0],
          tint_transform: ->(tint) { tint },
        )
      }.to raise_error(ArgumentError, /unsupported tint transform/)

      expect {
        pdf.declare_spot_color(
          'PANTONE 185 C',
          alternate: [0, 100, 93, 0],
          tint_transform: { type: 0, size: 2, samples: [0, 1] },
        )
      }.to raise_error(ArgumentError, /unsupported tint transform/)
    end

    it 'rejects multi-channel color spaces without an explicit tint transform' do
      expect {
        pdf.declare_spot_color(
          ['PANTONE 185 C', 'PANTONE 300 C'],
          alternate: [0, 100, 93, 0],
        )
      }.to raise_error(ArgumentError, /tint transform/)
    end

    it 'rejects Type 2 tint transforms for multi-channel color spaces' do
      expect {
        pdf.declare_spot_color(
          ['PANTONE 185 C', 'PANTONE 300 C'],
          alternate: [0, 100, 93, 0],
          tint_transform: { type: 2, c0: [0, 0, 0, 0], c1: [0, 1, 0.93, 0] },
        )
      }.to raise_error(ArgumentError, /single colorant channel/)
    end
  end

  describe 'fill_spot_color and stroke_spot_color' do
    it 'sets the fill color space and tint in the content stream' do
      pdf.fill_spot_color(red, 0.8)

      expect(pdf.render).to match(%r{/CS1 cs\n0\.8 scn})
    end

    it 'sets the stroke color space and tint in the content stream' do
      pdf.stroke_spot_color(red, 0.8)

      expect(pdf.render).to match(%r{/CS1 CS\n0\.8 SCN})
    end

    it 'sets multiple tints for DeviceN color spaces' do
      duo = pdf.declare_spot_color(
        ['PANTONE 185 C', 'PANTONE 300 C'],
        alternate: [0, 100, 93, 0],
        tint_transform: '{ 1 exch sub 0.93 mul exch 1 exch sub 0.56 mul 0 0.18 }',
      )
      pdf.fill_spot_color(duo, 0.5, 0.9)

      expect(pdf.render).to match(%r{/CS1 cs\n0\.5 0\.9 scn})
    end

    it 'registers the color space in the page resources' do
      pdf.fill_spot_color(red, 1)

      expect(pdf.page.resources[:ColorSpace].keys).to eq([:CS1])
    end

    it 'rejects an incorrect number of tint values' do
      expect { pdf.fill_spot_color(red, 0.5, 0.5) }
        .to raise_error(ArgumentError, /wrong number of tint values/)
    end

    it 'rejects tint values outside 0..1' do
      expect { pdf.fill_spot_color(red, 1.5) }
        .to raise_error(ArgumentError, /between 0 and 1/)
    end

    it 'rejects undeclared color spaces' do
      expect { pdf.fill_spot_color(:PANTONE_185_C, 0.5) }
        .to raise_error(ArgumentError, /declare_spot_color/)
    end
  end

  describe 'graphics state' do
    it 'restores fill and stroke spot colors on restore_graphics_state' do
      pdf.fill_spot_color(red, 0.5)
      pdf.stroke_spot_color(blue, 0.25)

      pdf.save_graphics_state
      pdf.fill_color('ff0000')
      pdf.stroke_color(0, 0, 0, 0)
      pdf.restore_graphics_state

      expect(pdf.graphic_state.fill_color).to eq(
        Prawn::Graphics::SpotColor::SpotColorValue.new(red, [0.5]),
      )
      expect(pdf.graphic_state.stroke_color).to eq(
        Prawn::Graphics::SpotColor::SpotColorValue.new(blue, [0.25]),
      )
      expect(pdf.graphic_state.color_space[:fill]).to eq(:CS1)
      expect(pdf.graphic_state.color_space[:stroke]).to eq(:CS2)
    end

    it 'does not re-emit the color space after it has been restored' do
      pdf.fill_spot_color(red, 0.5)
      pdf.save_graphics_state
      pdf.fill_color('ff0000')
      pdf.restore_graphics_state
      pdf.fill_spot_color(red, 0.8)

      str = pdf.render
      expect(str.scan('/CS1 cs').length).to eq(1)
      expect(str).to include('0.8 scn')
    end

    it 're-emits the color space on a new page' do
      pdf.fill_spot_color(red, 0.5)
      pdf.start_new_page

      str = pdf.render
      expect(str.scan('/CS1 cs').length).to eq(2)
      expect(pdf.page.resources[:ColorSpace].keys).to eq([:CS1])
    end
  end

  describe 'two spot colors overprinting' do
    it 'keeps two independent colorant channels in the output' do
      overprint_state = pdf.ref!(Type: :ExtGState, OP: true, op: true)
      pdf.page.resources[:ExtGState] ||= {}
      pdf.page.resources[:ExtGState][:GS1] = overprint_state
      pdf.renderer.add_content('/GS1 gs')

      pdf.fill_spot_color(red, 1)
      pdf.fill_circle([170, 500], 60)

      pdf.fill_spot_color(blue, 0.8)
      pdf.fill_circle([230, 500], 60)

      pdf.fill_spot_color(red, 0.6)
      pdf.draw_text('Two spot colors overprinting', at: [100, 400])

      spaces = analyze_color_spaces(pdf).values
      separations = spaces.select { |space|
        space[:definition][0] == :Separation
      }
      colorant_names = separations.map { |space| space[:definition][1] }
      expect(colorant_names).to contain_exactly(
        :'PANTONE 185 C',
        :'PANTONE 300 C',
      )

      functions = separations.map { |space| space[:function] }.uniq
      expect(functions.length).to eq(2)

      expect(pdf.render).to include('/OP true')
    end
  end
end
