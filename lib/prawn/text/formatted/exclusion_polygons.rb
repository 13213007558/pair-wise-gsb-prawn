# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # Horizontal intervals left inside a text box after removing polygons.
      #
      # @private
      class ExclusionPolygons
        def initialize(polygons)
          raw_polygons = Array(polygons)
          first_point = raw_polygons.first
          if first_point.is_a?(Array) && !first_point.first.is_a?(Array)
            raw_polygons = [raw_polygons]
          end

          @polygons = raw_polygons.map do |polygon|
            points = Array(polygon).map do |point|
              point.map { |coordinate| coordinate.to_f }
            end

            if points.length < 3
              raise ArgumentError, 'exclusion polygons need at least three points'
            end

            points
          end
        end

        def intervals(left, right, top, bottom)
          occupied = @polygons.flat_map do |polygon|
            occupied_intervals(polygon, left, right, top, bottom)
          end

          merge(occupied).reduce([[left, right]]) do |available, (block_left, block_right)|
            available.flat_map do |interval_left, interval_right|
              if block_right <= interval_left || block_left >= interval_right
                [[interval_left, interval_right]]
              else
                [
                  [interval_left, [block_left, interval_right].min],
                  [[block_right, interval_left].max, interval_right],
                ].reject { |new_left, new_right| new_right - new_left <= 0.000001 }
              end
            end
          end
        end

        def contains?(x, y)
          @polygons.any? do |polygon|
            cross_section(polygon, y).any? do |left, right|
              x > left && x < right
            end
          end
        end

        def intersects_rectangle?(left, bottom, right, top)
          @polygons.any? do |polygon|
            occupied_intervals(
              polygon, left, right, top, bottom
            ).any? do |block_left, block_right|
              block_left < right && block_right > left
            end
          end
        end

        private

        def occupied_intervals(polygon, left, right, top, bottom)
          polygon_min_x = polygon.map(&:first).min
          polygon_max_x = polygon.map(&:first).max
          polygon_min_y = polygon.map(&:last).min
          polygon_max_y = polygon.map(&:last).max
          band_top = [bottom, polygon_max_y].min
          band_bottom = [top, polygon_min_y].max

          return [] if band_bottom <= band_top
          return [] if polygon_max_x <= left || polygon_min_x >= right

          levels = polygon.map(&:last)
            .select { |y| y > band_top && y < band_bottom }
            .uniq
            .sort
          levels = [band_top, *levels, band_bottom]

          cross_sections = levels.each_cons(2).map do |upper, lower|
            merge(
              cross_section(polygon, (upper + lower) / 2.0).map do |block_left, block_right|
                [[block_left, left].max, [block_right, right].min]
              end.select do |block_left, block_right|
                block_right > block_left
              end,
            )
          end

          merge(cross_sections.flatten(1))
        end

        def cross_section(polygon, y)
          intersections = []

          points = polygon.first == polygon.last ? polygon[0..-2] : polygon
          points.each_with_index do |point1, index|
            point2 = points[(index + 1) % points.length]
            y1 = point1.last
            y2 = point2.last
            next unless y >= [y1, y2].min && y < [y1, y2].max

            intersection =
              point1.first +
                (point2.first - point1.first) * ((y - y1) / (y2 - y1))
            intersections << intersection
          end

          inside = false
          intersections.sort.each_with_object([]) do |x, intervals|
            inside = !inside
            if inside
              intervals << [x, nil]
            else
              intervals.last[1] = x
            end
          end
        end

        def merge(intervals)
          intervals.sort_by(&:first).each_with_object([]) do |interval, merged|
            if merged.empty? || interval.first > merged.last.last
              merged << interval.dup
            elsif interval.last > merged.last.last
              merged[merged.length - 1][1] = interval.last
            end
          end
        end

      end
    end
  end
end
