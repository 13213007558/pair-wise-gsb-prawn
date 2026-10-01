# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # Computes the horizontal intervals available for text on a vertical
      # band when floating exclusion regions (polygons) are present.
      #
      # Each polygon is a simple (non self-intersecting) polygon described by
      # its vertices. Polygons may be concave. When several polygons are
      # given they must not intersect each other.
      #
      # All coordinates are relative to the document bounds.
      #
      # @private
      class ExclusionZones
        # @param polygons [Array<Array<Array(Number, Number)>>]
        def initialize(polygons)
          @polygons = polygons.map { |polygon|
            polygon.map { |(x, y)| [Float(x), Float(y)] }
          }
        end

        # Horizontal intervals available for text within the vertical band
        # from y_bottom to y_top, restricted to the range left..right.
        #
        # @param y_bottom [Number]
        # @param y_top [Number]
        # @param left [Number]
        # @param right [Number]
        # @return [Array<Array(Number, Number)>]
        #   Sorted, non-overlapping intervals.
        def available_intervals(y_bottom, y_top, left, right)
          intervals = []
          cursor = left

          excluded_intervals(y_bottom, y_top).each do |(ex_left, ex_right)|
            ex_left = ex_left.clamp(left, right)
            ex_right = ex_right.clamp(left, right)
            next if ex_right <= cursor

            intervals << [cursor, ex_left] if ex_left > cursor
            cursor = ex_right
          end
          intervals << [cursor, right] if right > cursor

          intervals
        end

        private

        # Merged intervals covered by the polygons anywhere inside the
        # vertical band from y_bottom to y_top.
        def excluded_intervals(y_bottom, y_top)
          y_bottom, y_top = y_top, y_bottom if y_bottom > y_top

          # The excluded intervals can only change where a polygon vertex
          # crosses the band, so scan one horizontal line per sub-band.
          samples = [y_bottom, y_top]
          @polygons.each do |polygon|
            polygon.each do |(_, y)|
              samples << y if y > y_bottom && y < y_top
            end
          end
          samples = samples.uniq.sort

          excluded = []
          if samples.length == 1
            excluded.concat(scanline_intervals(samples.first))
          else
            samples.each_cons(2) do |lower, upper|
              excluded.concat(scanline_intervals((lower + upper) * 0.5))
            end
          end

          merge_intervals(excluded)
        end

        # Intervals covered by the polygons on the horizontal line at y,
        # using the even-odd fill rule.
        def scanline_intervals(y)
          crossings = []
          @polygons.each do |polygon|
            polygon.each_index do |index|
              x1, y1 = polygon[index]
              x2, y2 = polygon[(index + 1) % polygon.length]
              next if y1 == y2
              next unless (y1 <= y && y < y2) || (y2 <= y && y < y1)

              crossings << (x1 + (((y - y1) * (x2 - x1)) / (y2 - y1)))
            end
          end
          crossings.sort!
          crossings.each_slice(2).map { |(a, b)| [a, b] }
        end

        def merge_intervals(intervals)
          intervals.sort_by(&:first).each_with_object([]) do |interval, merged|
            if merged.empty? || interval[0] > merged.last[1]
              merged << interval.dup
            elsif interval[1] > merged.last[1]
              merged.last[1] = interval[1]
            end
          end
        end
      end
    end
  end
end
