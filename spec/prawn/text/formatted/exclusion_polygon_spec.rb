# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Text::Formatted::ExclusionPolygon do
  let(:polygon) do
    described_class.new([
      [0, 460], [500, 460], [500, 430], [300, 430],
      [300, 300], [200, 300], [200, 430], [0, 430]
    ])
  end

  it 'keeps disconnected intervals around a concave polygon footprint' do
    expect(polygon.available_intervals(0, 500, 420, 410)).to eq([
      [0.0, 200.0],
      [300.0, 500.0],
    ])
  end

  it 'does not use the polygon bounding box as the excluded area' do
    expect(polygon.available_intervals(0, 500, 395, 385)).to eq([
      [0.0, 200.0],
      [300.0, 500.0],
    ])
  end

  it 'makes the whole band available below the concave polygon' do
    expect(polygon.available_intervals(0, 500, 295, 285)).to eq([
      [0.0, 500.0]
    ])
  end
end
