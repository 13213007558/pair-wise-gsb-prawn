# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Prawn spot colors' do
  let(:pdf) { create_pdf }

  def page_resources(document = pdf)
    rendered = document.render
    reader = PDF::Reader.new(StringIO.new(rendered))
    reader.page(1).send(:resources)
  end

  it 'registers Separation colors as independent color spaces' do
    gold = pdf.separation_color(
      'Gold Spot', :DeviceRGB,
      FunctionType: 2, C0: [1, 0.9, 0.5], C1: [0.9, 0.7, 0], N: 1
    )
    blue = pdf.separation_color(
      'Blue Spot', :DeviceRGB,
      FunctionType: 2, C0: [0.7, 0.9, 1], C1: [0, 0.25, 0.8], N: 1
    )

    pdf.overprint do
      pdf.fill_color(gold, 0.9)
      pdf.fill_rectangle([0, 100], 100, 100)
      pdf.fill_color(blue, 0.8)
      pdf.fill_rectangle([50, 100], 100, 100)
    end

    color_spaces = page_resources.color_spaces
    expect(color_spaces.length).to eq(2)
    expect(color_spaces.values.map { |space| space[1] }).to eq(
      [:'Gold Spot', :'Blue Spot'],
    )
    expect(color_spaces.values.map(&:first)).to all(eq(:Separation))

    graphic_states = page_resources.graphic_states
    expect(graphic_states.values).to include(
      a_hash_including(op: true, OP: true, OPM: 1),
    )
  end

  it 'registers reused spot color resources on each page' do
    spot = pdf.separation_color(
      'Reused Spot', :DeviceGray,
      FunctionType: 2, C0: [0.9], C1: [0.1], N: 1
    )

    pdf.fill_color(spot, 0.2)
    pdf.fill_rectangle([0, 100], 10, 10)
    pdf.start_new_page
    pdf.fill_color(spot, 0.3)
    pdf.fill_rectangle([0, 100], 10, 10)

    rendered = pdf.render
    reader = PDF::Reader.new(StringIO.new(rendered))

    2.times do |index|
      spaces = reader.page(index + 1).send(:resources).color_spaces
      expect(spaces.fetch(:SpotCS1)[1]).to eq(:'Reused Spot')
    end
  end

  it 'accepts an explicitly named function option' do
    spot = pdf.spot_color(
      'Explicit Function',
      alternate: :DeviceRGB,
      function: { FunctionType: 2, C1: [0.2, 0.4, 0.6], N: 1 },
      tint: 0.5,
    )

    expect(spot.values).to eq([0.5])
    pdf.fill_color(spot)
    pdf.fill_rectangle([0, 100], 10, 10)

    function = page_resources.color_spaces.fetch(:SpotCS1)[3]
    expect(function[:C1]).to eq([0.2, 0.4, 0.6])
  end

  it 'does not reuse resources for same name with different transforms' do
    first = pdf.separation_color(
      'Same Spot', :DeviceRGB,
      FunctionType: 2, C0: [1, 0, 0], C1: [0, 1, 0], N: 1
    )
    second = pdf.separation_color(
      'Same Spot', :DeviceRGB,
      FunctionType: 2, C0: [0, 0, 1], C1: [1, 1, 0], N: 2
    )

    pdf.fill_color(first)
    pdf.fill_rectangle([0, 100], 10, 10)
    pdf.fill_color(second)
    pdf.fill_rectangle([20, 100], 10, 10)

    color_spaces = page_resources.color_spaces
    expect(color_spaces.length).to eq(2)
    functions = color_spaces.values.map { |space| space[3] }
    expect(functions.map { |function| function[:C1] }).to eq(
      [[0, 1, 0], [1, 1, 0]],
    )
    expect(functions.map { |function| function[:N] }).to eq([1, 2])
  end

  it 'encodes DeviceN names, values, and a Type 4 tint transform' do
    device_n = pdf.device_n_color(
      %i[GoldSpot BlueSpot],
      :DeviceRGB,
      FunctionType: 4,
      Domain: [0, 1, 0, 1],
      Program: <<~POSTSCRIPT,
        dup
        0.85 mul
        2 index 0.15 mul add
        2 index 0.8 mul
        2 index 0.8 mul
        5 3 roll
        pop
        pop
      POSTSCRIPT
    )

    pdf.fill_color(device_n, 0.75, 0.4)
    pdf.fill_rectangle([0, 100], 100, 100)

    color_spaces = page_resources.color_spaces
    space = color_spaces.fetch(:SpotCS1)
    expect(space[0..2]).to eq([:DeviceN, %i[GoldSpot BlueSpot], :DeviceRGB])
    expect(space[3]).to be_a(PDF::Reader::Stream)
    expect(space[3].hash).to include(FunctionType: 4, Domain: [0, 1, 0, 1])
    expect(pdf.render).to include("/SpotCS1 cs\n0.75 0.4 scn")
  end

  it 'restores fill and stroke spot colors after graphics state restore' do
    fill_spot = pdf.separation_color(
      'Fill Spot', :DeviceGray,
      FunctionType: 2, C0: [0.9], C1: [0.1], N: 1
    )
    stroke_spot = pdf.separation_color(
      'Stroke Spot', :DeviceGray,
      FunctionType: 2, C0: [0.8], C1: [0.2], N: 1
    )

    pdf.fill_color(fill_spot, 0.3)
    pdf.stroke_color(stroke_spot, 0.6)
    pdf.save_graphics_state
    pdf.fill_color 'ff0000'
    pdf.stroke_color '00ff00'
    pdf.restore_graphics_state

    expect(pdf.graphic_state.fill_color).to have_attributes(
      resource_name: 'SpotCS1', values: [0.3],
    )
    expect(pdf.graphic_state.stroke_color).to have_attributes(
      resource_name: 'SpotCS2', values: [0.6],
    )

    pdf.fill_color(fill_spot, 0.4)
    pdf.stroke_color(stroke_spot, 0.7)
    pdf.fill_rectangle([0, 100], 10, 10)
    pdf.stroke_rectangle([20, 100], 10, 10)

    expect(pdf.graphic_state.fill_color).to have_attributes(
      resource_name: 'SpotCS1', values: [0.4],
    )
    expect(pdf.graphic_state.stroke_color).to have_attributes(
      resource_name: 'SpotCS2', values: [0.7],
    )

    rendered = pdf.render
    expect(rendered).to match(
      %r{Q\n(?:/SpotCS1 cs\n)?0.4 scn.*?(?:/SpotCS2 CS\n)?0.7 SCN}m,
    )
    expect(rendered).to include("/SpotCS1 cs\n0.3 scn")
    expect(rendered).to include("/SpotCS2 CS\n0.6 SCN")
  end

  it 'rejects functions that cannot be encoded explicitly' do
    expect do
      pdf.separation_color(
        'Unsupported', :DeviceRGB,
        FunctionType: 3, Functions: []
      )
    end.to raise_error(ArgumentError, /unsupported spot-color tint/)

    expect do
      pdf.separation_color('Unsupported', :DeviceRGB, ->(tint) { tint })
    end.to raise_error(ArgumentError, /unsupported spot-color tint transform/)
  end
end
