# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # A polygon-shaped area where text box lines may not be drawn.
      #
      # @private
      class ExclusionPolygon
        EPSILON = 1e-9

        attr_reader :points

        def initialize(points)
          points = points.each_slice(2).to_a if points.first.is_a?(Numeric)
          points = points.points if points.respond_to?(:points)

          @points = points.map { |point| point.map(&:to_f) }

          return if @points.length >= 3

          raise ArgumentError, 'an exclusion polygon requires at least 3 points'
        end

        # Return the parts of a horizontal band outside this polygon. The
        # polygon's full footprint in the band is removed so that the complete
        # em-height rectangle of a line can never overlap the shape.
        def available_intervals(left, right, top, bottom)
          intervals = [[left.to_f, right.to_f]]

          occupied_intervals(top, bottom).each do |occupied_left, occupied_right|
            intervals = subtract_interval(
              intervals,
              occupied_left.clamp(left, right),
              occupied_right.clamp(left, right),
            )
          end

          intervals.select { |interval_left, interval_right|
            interval_right - interval_left > EPSILON
          }
        end

        private

        def occupied_intervals(top, bottom)
          event_ys = [top.to_f, bottom.to_f]

          @points.each do |_x, y|
            event_ys << y if y > bottom && y < top
          end

          event_ys.sort!.uniq!
          spans = []

          event_ys.each_cons(2) do |lower, higher|
            next if higher - lower <= EPSILON

            spans.concat(cross_section((lower + higher) * 0.5))
          end
          merge_intervals(spans)
        end

        def cross_section(y)
          intersections = []
          horizontal_spans = []

          @points.each_cons(2) do |(x1, y1), (x2, y2)|
            if y1 == y2
              next unless y == y1

              horizontal_spans << [[x1, x2].min, [x1, x2].max]
            elsif crossing_y?(y, y1, y2)
              intersections << x1 + ((y - y1) * (x2 - x1) / (y2 - y1))
            end
          end

          closure_edge = [@points.last, @points.first]
          (x1, y1), (x2, y2) = closure_edge.map(&:dup)
          if y1 != y2 && crossing_y?(y, y1, y2)
            intersections << x1 + ((y - y1) * (x2 - x1) / (y2 - y1))
          elsif y1 == y2 && y == y1
            horizontal_spans << [[x1, x2].min, [x1, x2].max]
          end

          spans = intersections.sort.each_slice(2).to_a
          merge_intervals(spans.concat(horizontal_spans))
        end

        def crossing_y?(y, y1, y2)
          lower = [y1, y2].min
          upper = [y1, y2].max
          y >= lower - EPSILON && y < upper - EPSILON
        end

        def subtract_interval(intervals, removed_left, removed_right)
          return intervals if removed_right - removed_left <= EPSILON

          intervals.flat_map do |left, right|
            next [[left, right]] if right <= removed_left || left >= removed_right

            remaining = []
            remaining << [left, removed_left] if left < removed_left
            remaining << [removed_right, right] if removed_right < right
            remaining
          end
        end

        def merge_intervals(intervals)
          return [] if intervals.empty?

          intervals = intervals.map { |left, right| [left, right].sort }.sort
          merged = [intervals.first.dup]

          intervals.each do |left, right|
            last_left, last_right = merged.last
            if left <= last_right + EPSILON
              merged[-1] = [last_left, [last_right, right].max]
            else
              merged << [left, right]
            end
          end

          merged
        end
      end
    end
  end
end
