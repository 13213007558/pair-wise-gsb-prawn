# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Graphics::SpotColor do
  let(:pdf) { create_pdf }

  let(:red) do
    pdf.register_separation(
      'Brand Red',
      alternate: :DeviceCMYK,
      c1: [0, 100, 85, 5],
    )
  end

  let(:yellow) do
    pdf.register_separation(
      'Brand Yellow',
      alternate: :DeviceCMYK,
      c1: [0, 25, 100, 0],
    )
  end

  let(:mix) do
    pdf.register_device_n(
      ['Brand Red', 'Brand Yellow'],
      alternate: :DeviceCMYK,
      tint_transform:
        '{ 2 copy 0.25 mul add 3 1 roll ' +          'exch dup 0.05 mul 3 1 roll 0.85 mul add ' +          'exch 0 4 1 roll }',
    )
  end

  # All graphics state operators relevant to colors, in order of appearance.
  def color_operators(pdf)
    operators = pdf.render.each_line.map(&:strip).select { |line|
      line.match?(/^(q|Q)$/) ||
        line.match?(%r{^/[A-Za-z0-9]+ (cs|CS)$}) ||
        line.match?(/^[0-9. ]+ (scn|SCN)$/)
    }
    # Strip the implicit q ... Q pair Prawn wraps page contents in.
    operators = operators[1..] if operators.first == 'q'
    operators = operators[0..-2] if operators.last == 'Q'
    operators
  end

  def page_color_spaces(rendered, page: 0)
    PDF::Reader.new(StringIO.new(rendered)).pages[page]
      .send(:resources).color_spaces
  end

  describe 'register_separation' do
    it 'declares a Separation color space in the page resources' do
      pdf.fill_spot_color(red, 0.75)
      pdf.fill_rectangle([0, 100], 100, 100)

      color_spaces = page_color_spaces(pdf.render)
      expect(color_spaces[red.resource_name.to_sym]).to eq(
        [
          :Separation,
          :"Brand Red",
          :DeviceCMYK,
          {
            C0: [0, 0, 0, 0],
            C1: [0, 100, 85, 5],
            Domain: [0, 1],
            FunctionType: 2,
            N: 1,
          },
        ],
      )
    end

    it 'escapes colorant names with special characters' do
      pdf.fill_spot_color(red, 1)
      expect(pdf.render).to include('/Separation /Brand#20Red /DeviceCMYK')
    end

    it 'returns the existing color space on identical re-registration' do
      again = pdf.register_separation(
        'Brand Red',
        alternate: :DeviceCMYK,
        c1: [0, 100, 85, 5],
      )
      expect(again).to equal(red)
    end

    it 'refuses to re-register a colorant with a different definition' do
      red
      expect {
        pdf.register_separation(
          'Brand Red',
          alternate: :DeviceCMYK,
          c1: [0, 0, 0, 100],
        )
      }.to raise_error(Prawn::Errors::IncompatibleSpotColor)
    end

    it 'refuses to re-register a colorant with a different alternate color space' do
      red
      expect {
        pdf.register_separation(
          'Brand Red',
          alternate: :DeviceRGB,
          c1: [1, 0, 0],
        )
      }.to raise_error(Prawn::Errors::IncompatibleSpotColor)
    end

    it 'assigns a unique resource name to each color space' do
      expect(red.resource_name).to_not eq(yellow.resource_name)
    end

    it 'raises an error for an unknown alternate color space' do
      expect {
        pdf.register_separation('Spot', alternate: :DeviceN, c1: [1])
      }.to raise_error(ArgumentError)
    end

    it 'raises an error when neither c1 nor tint_transform is given' do
      expect {
        pdf.register_separation('Spot')
      }.to raise_error(ArgumentError)
    end

    it 'raises an error when both c1 and tint_transform are given' do
      expect {
        pdf.register_separation('Spot', c1: [1], tint_transform: '{ }')
      }.to raise_error(ArgumentError)
    end

    it 'raises an error when c1 does not match the alternate color space' do
      expect {
        pdf.register_separation('Spot', alternate: :DeviceCMYK, c1: [1, 0, 0])
      }.to raise_error(ArgumentError)
    end

    it 'accepts a PostScript calculator tint transform' do
      spot = pdf.register_separation(
        'Spot',
        alternate: :DeviceRGB,
        tint_transform: '{ dup dup }',
      )
      pdf.fill_spot_color(spot, 0.5)

      color_spaces = page_color_spaces(pdf.render)
      space = color_spaces[spot.resource_name.to_sym]
      expect(space[0..2]).to eq([:Separation, :Spot, :DeviceRGB])
      expect(space[3].hash).to include(
        FunctionType: 4,
        Domain: [0, 1],
        Range: [0, 1, 0, 1, 0, 1],
      )
      expect(space[3].unfiltered_data).to eq('{ dup dup }')
    end
  end

  describe 'register_device_n' do
    it 'declares a DeviceN color space in the page resources' do
      pdf.fill_spot_color(mix, 0.5, 0.25)
      pdf.fill_rectangle([0, 100], 100, 100)

      color_spaces = page_color_spaces(pdf.render)
      space = color_spaces[mix.resource_name.to_sym]
      expect(space[0..2]).to eq(
        [:DeviceN, [:"Brand Red", :"Brand Yellow"], :DeviceCMYK],
      )
      expect(space[3].hash).to include(
        FunctionType: 4,
        Domain: [0, 1, 0, 1],
        Range: [0, 1, 0, 1, 0, 1, 0, 1],
      )
      expect(space[3].unfiltered_data).to include('2 copy 0.25 mul add')
    end

    it 'returns the existing color space on identical re-registration' do
      again = pdf.register_device_n(
        ['Brand Red', 'Brand Yellow'],
        alternate: :DeviceCMYK,
        tint_transform:
          '{ 2 copy 0.25 mul add 3 1 roll ' +            'exch dup 0.05 mul 3 1 roll 0.85 mul add ' +            'exch 0 4 1 roll }',
      )
      expect(again).to equal(mix)
    end

    it 'refuses to re-register the colorants with a different tint transform' do
      mix
      expect {
        pdf.register_device_n(
          ['Brand Red', 'Brand Yellow'],
          alternate: :DeviceCMYK,
          tint_transform: '{ add }',
        )
      }.to raise_error(Prawn::Errors::IncompatibleSpotColor)
    end

    it 'raises an error without a tint transform' do
      expect {
        pdf.register_device_n(['A', 'B'])
      }.to raise_error(ArgumentError)
    end

    it 'raises an error without colorant names' do
      expect {
        pdf.register_device_n([], tint_transform: '{ }')
      }.to raise_error(ArgumentError)
    end
  end

  describe 'fill_spot_color' do
    it 'emits the color space and tint operators' do
      pdf.fill_spot_color(red, 0.75)

      expect(color_operators(pdf)).to eq(
        ["/#{red.resource_name} cs", '0.75 scn'],
      )
    end

    it 'emits one tint value per colorant for DeviceN color spaces' do
      pdf.fill_spot_color(mix, 0.5, 0.25)

      expect(color_operators(pdf)).to eq(
        ["/#{mix.resource_name} cs", '0.5 0.25 scn'],
      )
    end

    it 'does not set the same color space twice' do
      pdf.fill_spot_color(red, 0.5)
      pdf.fill_spot_color(red, 0.75)

      expect(color_operators(pdf)).to eq(
        ["/#{red.resource_name} cs", '0.5 scn', '0.75 scn'],
      )
    end

    it 'resolves a registered separation by colorant name' do
      red
      pdf.fill_spot_color('Brand Red', 0.5)

      expect(color_operators(pdf)).to eq(
        ["/#{red.resource_name} cs", '0.5 scn'],
      )
    end

    it 'raises an error for an unregistered colorant name' do
      expect {
        pdf.fill_spot_color('Unknown', 0.5)
      }.to raise_error(ArgumentError)
    end

    it 'raises an error for a wrong number of tints' do
      expect { pdf.fill_spot_color(mix, 0.5) }.to raise_error(ArgumentError)
    end

    it 'raises an error for tints out of range' do
      expect { pdf.fill_spot_color(red, 1.5) }.to raise_error(ArgumentError)
    end
  end

  describe 'stroke_spot_color' do
    it 'emits the color space and tint operators' do
      pdf.stroke_spot_color(red, 0.75)

      expect(color_operators(pdf)).to eq(
        ["/#{red.resource_name} CS", '0.75 SCN'],
      )
    end

    it 'tracks fill and stroke color spaces independently' do
      pdf.fill_spot_color(red, 0.5)
      pdf.stroke_spot_color(yellow, 0.25)

      expect(color_operators(pdf)).to eq(
        [
          "/#{red.resource_name} cs", '0.5 scn',
          "/#{yellow.resource_name} CS", '0.25 SCN',
        ],
      )
    end
  end

  describe 'graphics state' do
    it 'uses the correct color space after nested save/restore' do
      pdf.fill_spot_color(red, 0.5)
      pdf.save_graphics_state do
        pdf.fill_color('ff0000')
        pdf.save_graphics_state do
          pdf.fill_spot_color(yellow, 0.25)
        end
        # PDF Q restored the DeviceRGB fill color space, so only the new
        # color values need to be emitted here.
        pdf.fill_color('0000ff')
      end
      # PDF Q restored the spot color space, so only the new tint is emitted.
      pdf.fill_spot_color(red, 0.75)

      expect(color_operators(pdf)).to eq(
        [
          "/#{red.resource_name} cs",
          '0.5 scn',
          'q',
          '/DeviceRGB cs',
          '1.0 0.0 0.0 scn',
          'q',
          "/#{yellow.resource_name} cs",
          '0.25 scn',
          'Q',
          '0.0 0.0 1.0 scn',
          'Q',
          '0.75 scn',
        ],
      )
    end

    it 're-applies the spot color space and tint on a new page' do
      pdf.fill_spot_color(red, 0.5)
      pdf.fill_rectangle([0, 100], 100, 100)
      pdf.start_new_page
      pdf.fill_rectangle([0, 100], 100, 100)

      expect(color_operators(pdf)).to eq(
        [
          "/#{red.resource_name} cs",
          '0.5 scn',
          # page boundary: previous page graphics state is closed and a new
          # one is opened
          'Q',
          'q',
          "/#{red.resource_name} cs",
          '0.5 scn',
        ],
      )

      rendered = pdf.render
      expect(page_color_spaces(rendered, page: 1)[red.resource_name.to_sym])
        .to eq(page_color_spaces(rendered, page: 0)[red.resource_name.to_sym])
    end
  end
end
