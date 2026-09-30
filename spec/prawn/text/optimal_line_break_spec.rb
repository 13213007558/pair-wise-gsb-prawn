# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Text::OptimalLineBreak do
  Item = described_class::Item

  def word(text, width: 10, hyphen: false)
    Item.new(
      kind: :box,
      text: text,
      width: width,
      stretch: 0,
      shrink: 0,
      spaces: 0,
      penalty: 0,
      forced: false,
      paragraph_end: false,
      hyphen: hyphen,
      break_after: hyphen,
    )
  end

  def glue(width: 3, stretch: 3, shrink: 1.5)
    Item.new(
      kind: :glue,
      text: ' ',
      width: width,
      stretch: stretch,
      shrink: shrink,
      spaces: 1,
      penalty: 0,
      forced: false,
      paragraph_end: false,
      hyphen: false,
      break_after: false,
    )
  end

  def hyphen_penalty(width: 1)
    Item.new(
      kind: :penalty,
      text: '-',
      width: width,
      stretch: 0,
      shrink: 0,
      spaces: 0,
      penalty: 0,
      forced: false,
      paragraph_end: false,
      hyphen: true,
      break_after: false,
    )
  end

  def paragraph_with(words, width: 40)
    items = []
    words.each_with_index do |value, index|
      text, item_width = Array(value)
      items << word(text, width: item_width)
      items << glue if index < words.length - 1
    end
    described_class.new(items, width: width).call
  end

  def breakpoint_indices(items)
    items.each_with_index.filter_map do |item, index|
      index if item.glue? || item.penalty? || item.break_after
    end
  end

  def brute_force(items, width)
    indices = breakpoint_indices(items)
    best = nil
    engine = described_class.new(items, width: width)
    breakpoints = engine.send(:breakpoints)
    virtual_start = breakpoints.first
    final_breakpoint = breakpoints.last

    (0..indices.length).each do |count|
      indices.combination(count) do |selected|
        selected_breakpoints =
          [
            virtual_start,
            *breakpoints.select { |breakpoint|
              selected.include?(breakpoint.index)
            },
            final_breakpoint,
          ]
        cost = 0
        previous_hyphen = false
        previous_class = 0
        feasible = true

        selected_breakpoints.each_cons(2) do |previous, breakpoint|
          metrics = engine.send(:line_metrics, previous, breakpoint)
          line = engine.send(:build_line, previous, breakpoint, metrics)
          if line.nil?
            feasible = false
            break
          end

          fitness_class = engine.send(
            :fitness_class, line.ratio, line.paragraph_end,
          )
          cost += line.cost + breakpoint.penalty.to_f
          cost += (fitness_class - previous_class).abs * 20
          cost += 1000 if line.hyphen && previous_hyphen
          previous_hyphen = line.hyphen
          previous_class = fitness_class
        end

        if feasible && (best.nil? || cost < best.first)
          best = [cost, selected]
        end
      end
    end

    best
  end

  it 'matches exhaustive line breaks for a small paragraph' do
    words = %w[aa bbbbb ccc dddd ee fffff gg hhhh]
    items = []
    words.each_with_index do |text, index|
      items << word(text, width: text.length * 4)
      items << glue if index < words.length - 1
    end

    result = described_class.new(items, width: 36).call
    expected_cost, expected_indices = brute_force(items, 36)

    actual_indices = result.lines[0...-1].map(&:breakpoint_index)
    expect(actual_indices).to eq(expected_indices)
    result_cost = result.lines.last.total_cost
    expect(result_cost).to be_within(1e-9).of(expected_cost)
  end

  it 'checks only candidate prefixes on long paragraphs' do
    items = []
    1000.times do |index|
      items << word("word#{index}", width: 20)
      items << glue unless index == 999
    end

    result = described_class.new(items, width: 100)
    result.call

    expect(result.evaluations).to be < 40_000
  end

  it 'penalizes consecutive optional hyphen breaks' do
    without_consecutive =
      [
        word('aa'), glue, word('bb'), glue,
        word('ccc'), glue, word('dd'),
      ]
    with_consecutive =
      [
        word('aa'), glue,
        word('bb'), hyphen_penalty, word('cc'), glue,
        word('dd'), hyphen_penalty, word('ee'),
      ]

    first = described_class.new(without_consecutive, width: 22).call
    second = described_class.new(with_consecutive, width: 22).call

    expect(second.lines.each_cons(2).none? { |a, b| a.hyphen && b.hyphen })
      .to be(true)
    expect(second.lines.sum(&:cost))
      .to be >= first.lines.sum(&:cost)
  end
end
