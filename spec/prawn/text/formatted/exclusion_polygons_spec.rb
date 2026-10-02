# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Text::Formatted::ExclusionPolygons do
  let(:polygon) do
    [
      [40, 100], [100, 100], [100, 60], [160, 60],
      [160, 100], [220, 100], [220, 0], [40, 0],
    ]
  end

  it 'keeps the indentation of a concave polygon instead of using a bounding box' do
    exclusions = described_class.new(polygon)

    expect(exclusions.intervals(0, 300, 59, 30)).to eq([
      [0, 40.0], [220.0, 300],
    ])
    expect(exclusions.intervals(0, 300, 99, 61)).to eq([
      [0, 40.0], [100.0, 160.0], [220.0, 300],
    ])
  end

  it 'detects rectangle overlap from full line height, not only the baseline' do
    exclusions = described_class.new(polygon)

    expect(exclusions.intersects_rectangle?(105, 55, 155, 95)).to be(true)
    expect(exclusions.intersects_rectangle?(0, 55, 39, 95)).to be(false)
  end

  it 'accepts one polygon without the outer array' do
    exclusions = described_class.new(polygon)

    expect(exclusions.intervals(0, 300, 99, 61).length).to eq(3)
  end
end
