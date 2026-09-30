# frozen_string_literal: true

module Prawn
  module Text
    # Chooses line breaks for a complete paragraph using dynamic programming.
    #
    # The input is a sequence of boxes, glue, penalties and forced breaks.
    # Unlike a greedy line wrapper, this class considers every feasible way to
    # reach each breakpoint and retains the minimum-cost path for each line
    # fitness class.
    #
    # @private
    class OptimalLineBreak
        class InfeasibleLayout < StandardError; end

      Item = Struct.new(
        :kind, :text, :width, :stretch, :shrink, :spaces,
        :penalty, :forced, :paragraph_end, :hyphen,
        :break_after, :metadata,
        keyword_init: true,
      ) do
        def glue?
          kind == :glue
        end

        def penalty?
          kind == :penalty
        end

        def marker?
          kind == :break
        end
      end

      Line = Struct.new(
        :start_index, :end_index, :breakpoint_index,
        :width, :adjustment, :ratio, :cost, :total_cost,
        :hyphen, :paragraph_end,
        keyword_init: true,
      )

      Breakpoint = Struct.new(
        :index, :include_item, :forced, :paragraph_end, :hyphen, :penalty,
        :box_forced,
        :marker, :box_break,
        keyword_init: true,
      ) do
        def marker?
          marker
        end

        def virtual_start?
          index == -1
        end
      end

      Candidate = Struct.new(
        :cost, :previous_index, :previous_class, :line, :total_cost,
        keyword_init: true,
      )

      Metrics = Struct.new(
        :width, :stretch, :shrink, :spaces, :minimum_width, :content_count,
        keyword_init: true,
      )

      FITNESS_DELTA_COST = 20
      HYPHEN_COST = 50
      CONSECUTIVE_HYPHEN_COST = 1000
      EPSILON = 1.0e-9

      attr_reader :lines, :evaluations

      def initialize(items, width:, justified: true, hyphen_cost: HYPHEN_COST)
        @items = items
        @width = width
        @justified = justified
        @hyphen_cost = hyphen_cost
        @evaluations = 0
      end

      def call
        candidates = Hash.new { |hash, key| hash[key] = Array.new(4) }
        candidates[-1][0] = Candidate.new(cost: 0)

        breakpoints.each do |breakpoint|
          evaluate_breakpoint(breakpoint, candidates)
        end

        final_breakpoint = breakpoints.last
        final_candidates = candidates[final_breakpoint.index].compact
        if final_candidates.empty?
          raise InfeasibleLayout, 'could not find a feasible line break'
        end

        final_candidate = final_candidates.min_by(&:cost)
        @lines = reconstruct(final_breakpoint, final_candidate, candidates)
        self
      end

      private

      def breakpoints
        @breakpoints ||= begin
          list = [
            Breakpoint.new(
              index: -1,
              include_item: false,
              forced: false,
              paragraph_end: false,
              hyphen: false,
              penalty: 0,
              marker: false,
              box_break: false,
              box_forced: false,
            ),
          ]

          @items.each_with_index do |item, index|
            if item.glue?
              list << breakpoint_for_glue(index, item)
            elsif item.penalty?
              list << breakpoint_for_penalty(index, item)
            elsif item.marker?
              list << breakpoint_for_marker(index, item)
            elsif item.break_after
              list << breakpoint_for_box(index, item)
            end
          end

          unless ends_with_paragraph_break?
            list << Breakpoint.new(
              index: @items.length,
              include_item: false,
              forced: true,
              paragraph_end: true,
              hyphen: false,
              penalty: 0,
              marker: false,
              box_break: false,
              box_forced: false,
            )
          end

          list
        end
      end

      def breakpoint_for_glue(index, item)
        Breakpoint.new(
          index: index,
          include_item: false,
          forced: false,
          paragraph_end: false,
          hyphen: false,
          penalty: 0,
          marker: false,
          box_break: false,
          box_forced: false,
        )
      end

      def breakpoint_for_penalty(index, item)
        Breakpoint.new(
          index: index,
          include_item: true,
          forced: item.forced,
          paragraph_end: false,
          hyphen: item.hyphen,
          penalty: item.penalty,
          marker: false,
          box_break: false,
          box_forced: false,
        )
      end

      def breakpoint_for_marker(index, item)
        Breakpoint.new(
          index: index,
          include_item: false,
          forced: true,
          paragraph_end: item.paragraph_end,
          hyphen: false,
          penalty: item.penalty,
          marker: true,
          box_break: false,
          box_forced: false,
        )
      end

      def breakpoint_for_box(index, item)
        Breakpoint.new(
          index: index,
          include_item: true,
          forced: item.forced,
          paragraph_end: false,
          hyphen: item.hyphen,
          penalty: item.penalty,
          marker: false,
          box_break: true,
          box_forced: item.forced,
        )
      end

      def ends_with_paragraph_break?
        @items.last && @items.last.marker? && @items.last.paragraph_end
      end

      def evaluate_breakpoint(breakpoint, candidates)
        previous_breakpoints(breakpoint).each do |previous|
          previous_candidates = candidates[previous.index]
          next if previous_candidates.nil?

          metrics = line_metrics(previous, breakpoint)
          if metrics.minimum_width > @width + EPSILON
            break
          end

          previous_candidates.each_with_index do |previous_candidate, fitness|
            next if previous_candidate.nil?

            line = build_line(previous, breakpoint, metrics)
            next unless line

            @evaluations += 1
            next_fitness = fitness_class(line.ratio, line.paragraph_end)
            cost =
              previous_candidate.cost +
              line.cost + breakpoint.penalty.to_f +
              fitness_delta_cost(fitness, next_fitness) +
              consecutive_hyphen_cost(previous_candidate, line)
            candidate = Candidate.new(
              cost: cost,
              previous_index: previous.index,
              previous_class: fitness,
              line: line,
              total_cost: cost,
            )
            candidate.line.total_cost = cost

            update_candidate(candidates[breakpoint.index], line, candidate)
          end
        end
      end

      def previous_breakpoints(breakpoint)
        previous = breakpoints
          .select { |candidate| candidate.index < breakpoint.index }
          .reverse
        candidates = []
        previous.each_with_index do |candidate, index|
          candidates << candidate
          break if index.positive? && candidate.forced && !candidate.box_forced
        end
        candidates
      end

      def line_metrics(previous_breakpoint, breakpoint)
        start_index = previous_breakpoint.index + 1
        end_index = line_end_index(breakpoint)

        width = 0.0
        spaces = 0
        total_stretch = 0.0
        total_shrink = 0.0
        content_count = 0
        last_index = end_index
        elastic_end_index = last_index
        if breakpoint.index < @items.length && @items[breakpoint.index]&.glue?
          elastic_end_index = breakpoint.index
        end
        if breakpoint.index == @items.length
          last_index -= 1 while last_index >= start_index && @items[last_index].glue?
        end

        (start_index..elastic_end_index).each do |index|
          item = @items[index]
          next if item.marker?
          next if item.penalty? && index != breakpoint.index
          next if item.glue? && index == start_index

          width += item.width unless index > last_index
          content_count += 1 unless item.glue?
          next unless item.glue?

          spaces += item.spaces
          total_stretch += item.stretch
          total_shrink += item.shrink
        end

        Metrics.new(
          width: width,
          stretch: total_stretch,
          shrink: total_shrink,
          spaces: spaces,
          minimum_width: width - total_shrink,
          content_count: content_count,
        )
      end

      def line_end_index(breakpoint)
        if breakpoint.marker?
          breakpoint.index
        elsif breakpoint.include_item || breakpoint.index == @items.length
          breakpoint.index - (breakpoint.index == @items.length ? 1 : 0)
        else
          breakpoint.index - 1
        end
      end

      def build_line(previous_breakpoint, breakpoint, metrics)
        if metrics.content_count.zero? &&
            !breakpoint.marker? && !breakpoint.box_forced
          return nil
        end

        last_line = breakpoint.paragraph_end
        ratio = adjustment_ratio(metrics, last_line)
        return nil unless feasible?(metrics, ratio, last_line)

        adjustment = line_adjustment(metrics, ratio, last_line)
        badness = line_badness(metrics, breakpoint, ratio, last_line)

        Line.new(
          start_index: previous_breakpoint.index + 1,
          end_index: line_end_index(breakpoint),
          breakpoint_index: breakpoint.index,
          width: metrics.width,
          adjustment: adjustment,
          ratio: ratio,
          cost: badness + (breakpoint.hyphen ? @hyphen_cost : 0),
          hyphen: breakpoint.hyphen,
          paragraph_end: last_line,
        )
      end

      def line_badness(metrics, breakpoint, ratio, last_line)
        return 0 if last_line
        return 1_000_000.0 if metrics.spaces.zero? && !breakpoint.hyphen

        100.0 * (finite_ratio(ratio).abs**3)
      end

      def adjustment_ratio(metrics, last_line)
        return 0.0 if last_line

        difference = @width - metrics.width
        if difference.positive?
          metrics.stretch.zero? ? Float::INFINITY : difference / metrics.stretch
        elsif difference.negative?
          metrics.shrink.zero? ? -Float::INFINITY : difference / metrics.shrink
        else
          0.0
        end
      end

      def feasible?(metrics, ratio, last_line)
        if ratio.infinite?
          ratio.positive? && metrics.width <= @width + EPSILON
        elsif last_line
          metrics.width <= @width + EPSILON
        else
          ratio >= -1.0 - EPSILON
        end
      end

      def line_adjustment(metrics, ratio, last_line)
        return 0.0 unless @justified && !last_line && metrics.spaces.positive?
        return 0.0 if ratio.infinite?

        difference = @width - metrics.width
        maximum_difference = metrics.stretch
        allowed_difference = [difference, maximum_difference].min
        allowed_difference / metrics.spaces
      end

      def fitness_class(ratio, last_line)
        return 1 if last_line
        return 3 if ratio.infinite? && ratio.positive?
        return 0 if ratio.infinite?

        if ratio < -0.5
          0
        elsif ratio <= 0.5
          1
        elsif ratio <= 1
          2
        else
          3
        end
      end

      def finite_ratio(ratio)
        ratio.infinite? ? 10.0 : ratio
      end

      def fitness_delta_cost(previous_class, next_class)
        (next_class - previous_class).abs * FITNESS_DELTA_COST
      end

      def consecutive_hyphen_cost(previous_candidate, line)
        if line.hyphen && previous_candidate.line && previous_candidate.line.hyphen
          CONSECUTIVE_HYPHEN_COST
        else
          0
        end
      end

      def update_candidate(target, line, candidate)
        fitness_class = fitness_class(line.ratio, line.paragraph_end)
        current = target[fitness_class]
        if current.nil? || candidate.cost < current.cost
          target[fitness_class] = candidate
        end
      end

      def reconstruct(final_breakpoint, final_candidate, candidates)
        result = []
        candidate = final_candidate

        while candidate
          result << candidate.line if candidate.line
          break if candidate.previous_index.nil?

          candidate =
            candidates[candidate.previous_index][candidate.previous_class]
        end

        result.reverse
      end
    end
  end
end
