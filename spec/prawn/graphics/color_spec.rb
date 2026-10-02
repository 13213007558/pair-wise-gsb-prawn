# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Graphics::Color do
  let(:pdf) { create_pdf }

  def exponential_transform(color)
    {
      FunctionType: 2,
      Domain: [0.0, 1.0],
      C0: [0.0, 0.0, 0.0],
      C1: color,
      N: 1.0,
    }
  end

  def rendered_page(document = pdf)
    reader = PDF::Reader.new(StringIO.new(document.render))
    reader.page(1)
  end

  describe 'Separation color spaces' do
    it 'writes the color space resource and paint operators' do
      red = pdf.define_separation_color_space(
        :BrandRed, :DeviceRGB, exponential_transform([1.0, 0.0, 0.0])
      )
      blue = pdf.define_separation_color_space(
        :BrandBlue, :DeviceRGB, exponential_transform([0.0, 0.0, 1.0])
      )

      pdf.fill_color(red, 0.75)
      pdf.rectangle([10, 100], 20, 20)
      pdf.fill

      pdf.stroke_color(blue, 0.5)
      pdf.rectangle([40, 100], 20, 20)
      pdf.stroke

      page = rendered_page
      color_spaces = page.color_spaces
      red_color_space = color_spaces[red.resource_name]
      blue_color_space = color_spaces[blue.resource_name]

      expect(color_spaces.keys).to include(
        red.resource_name, blue.resource_name
      )
      expect(red_color_space[0..2]).to eq([:Separation, :BrandRed, :DeviceRGB])
      expect(red_color_space[3]).to include(FunctionType: 2, C1: [1, 0, 0])
      expect(blue_color_space[0..2]).to eq([:Separation, :BrandBlue, :DeviceRGB])
      expect(blue_color_space[3]).to include(FunctionType: 2, C1: [0, 0, 1])
      expect(page.raw_content).to include("/#{red.resource_name} cs")
      expect(page.raw_content).to include('0.75 scn')
      expect(page.raw_content).to include("/#{blue.resource_name} CS")
      expect(page.raw_content).to include('0.5 SCN')
    end

    it 'reuses an identical definition and rejects an inconsistent one' do
      transform = exponential_transform([1.0, 0.0, 0.0])
      first = pdf.define_separation_color_space(
        :BrandRed, :DeviceRGB, transform
      )
      second = pdf.define_separation_color_space(
        :BrandRed, :DeviceRGB, transform
      )

      expect(second).to equal(first)

      expect do
        pdf.define_separation_color_space(
          :BrandRed, :DeviceRGB, exponential_transform([0.0, 0.5, 0.0])
        )
      end.to raise_error(
        ArgumentError, /already defined with a different alternate color space or tint transform/
      )

      expect do
        pdf.define_separation_color_space(
          :BrandBlue, :DeviceCMYK,
          exponential_transform([1.0, 0.0, 0.0, 0.0])
        )
        pdf.define_separation_color_space(
          :BrandBlue, :DeviceRGB,
          exponential_transform([1.0, 0.0, 0.0])
        )
      end.to raise_error(
        ArgumentError, /already defined with a different alternate color space or tint transform/
      )
    end
  end

  describe 'DeviceN color spaces' do
    it 'writes all colorants, the alternate space, tint transform, and tints' do
      red = pdf.define_separation_color_space(
        :BrandRed, :DeviceRGB, exponential_transform([1.0, 0.0, 0.0])
      )
      blue = pdf.define_separation_color_space(
        :BrandBlue, :DeviceRGB, exponential_transform([0.0, 0.0, 1.0])
      )
      mixed = pdf.define_device_n_color_space(
        [:BrandRed, :BrandBlue],
        alternate_color_space: :DeviceRGB,
        tint_transform: {
          FunctionType: 4,
          Domain: [0.0, 1.0, 0.0, 1.0],
          Range: [0.0, 1.0] * 3,
          stream: '{ 1 index 0 }',
        },
      )

      pdf.fill_color(red, 0.75)
      pdf.rectangle([10, 100], 20, 20)
      pdf.fill

      pdf.save_graphics_state do
        pdf.fill_color(mixed, 0.25, 0.75)
        pdf.rectangle([70, 100], 20, 20)
        pdf.fill
      end

      pdf.fill_color(red, 0.1)
      pdf.rectangle([100, 100], 20, 20)
      pdf.fill
      pdf.stroke_color(blue, 0.2)
      pdf.rectangle([100, 130], 20, 20)
      pdf.stroke

      page = rendered_page
      device_n = page.color_spaces[mixed.resource_name]

      expect(device_n[0..2]).to eq(
        [:DeviceN, [:BrandRed, :BrandBlue], :DeviceRGB]
      )
      expect(device_n[3]).to be_a(PDF::Reader::Stream)
      expect(device_n[3].unfiltered_data).to eq('{ 1 index 0 }')
      expect(page.raw_content).to include("/#{mixed.resource_name} cs")
      expect(page.raw_content).to include('0.25 0.75 scn')
      expect(page.raw_content).to match(
        %r{Q\n/#{red.resource_name} cs\n0\.1 scn}
      )
      expect(page.raw_content).to include("/#{blue.resource_name} CS")
      expect(page.raw_content).to include('0.2 SCN')
    end

    it 'isolates definitions that share colorant names but transform differently' do
      pdf.define_separation_color_space(
        :BrandRed, :DeviceRGB, exponential_transform([1.0, 0.0, 0.0])
      )

      first_mix = pdf.define_device_n_color_space(
        [:BrandRed, :BrandBlue],
        alternate_color_space: :DeviceRGB,
        tint_transform: {
          FunctionType: 4,
          Domain: [0.0, 1.0, 0.0, 1.0],
          Range: [0.0, 1.0] * 3,
          stream: '{ 1 index 0 }',
        }
      )
      second_mix = pdf.define_device_n_color_space(
        [:BrandRed, :BrandBlue],
        alternate_color_space: :DeviceRGB,
        tint_transform: {
          FunctionType: 4,
          Domain: [0.0, 1.0, 0.0, 1.0],
          Range: [0.0, 1.0] * 3,
          stream: '{ 1 index 0.5 mul 0 }',
        }
      )

      pdf.fill_color(first_mix, 0.2, 0.3)
      pdf.rectangle([10, 100], 20, 20)
      pdf.fill
      pdf.fill_color(second_mix, 0.4, 0.6)
      pdf.rectangle([40, 100], 20, 20)
      pdf.fill

      page = rendered_page
      color_spaces = page.color_spaces

      expect(first_mix.resource_name).to_not eq(second_mix.resource_name)
      expect(color_spaces.keys).to include(
        first_mix.resource_name, second_mix.resource_name
      )
      expect(
        color_spaces[first_mix.resource_name][3].unfiltered_data
      ).to eq('{ 1 index 0 }')
      expect(
        color_spaces[second_mix.resource_name][3].unfiltered_data
      ).to eq('{ 1 index 0.5 mul 0 }')
    end
  end

  describe 'graphics state' do
    it 'validates tint component counts and ranges' do
      red = pdf.define_separation_color_space(
        :BrandRed, :DeviceRGB, exponential_transform([1.0, 0.0, 0.0])
      )
      mixed = pdf.define_device_n_color_space(
        [:BrandRed, :BrandBlue],
        alternate_color_space: :DeviceRGB,
        tint_transform: {
          FunctionType: 4,
          Domain: [0.0, 1.0, 0.0, 1.0],
          Range: [0.0, 1.0] * 3,
          stream: '{ 1 index 0 }',
        }
      )

      expect { red.color(0.5, 0.5) }
        .to raise_error(ArgumentError, 'expected 1 tint value(s), got 2')
      expect { mixed.color(0.5) }
        .to raise_error(ArgumentError, 'expected 2 tint value(s), got 1')
      expect { red.color(1.1) }
        .to raise_error(
          ArgumentError,
          'tint values must be numbers between 0 and 1'
        )
    end
  end
end
