# frozen_string_literal: true

require_relative 'line_wrap'
require_relative 'arranger'
require_relative 'exclusion_polygon'

module Prawn
  module Text
    module Formatted
      # Handles text wrapping for for formatted text.
      #
      # @private
      module Wrap
        LineSegment = Struct.new(
          :left, :available_width, :width, :space_count,
          :paragraph_finished, :fragments,
        )

        def initialize(_array, options)
          @line_wrap = Prawn::Text::Formatted::LineWrap.new
          @arranger = Prawn::Text::Formatted::Arranger.new(
            @document,
            kerning: options[:kerning],
          )
          @disable_wrap_by_char = options[:disable_wrap_by_char]
          @exclusion_polygons = normalize_exclusion_polygons(options)
        end

        # See the developer documentation for PDF::Core::Text#wrap
        #
        # Formatted#wrap should set the following variables:
        #   <tt>@line_height</tt>::
        #        the height of the tallest fragment in the last printed line
        #   <tt>@descender</tt>::
        #        the descender height of the tallest fragment in the last
        #        printed line
        #   <tt>@ascender</tt>::
        #        the ascender heigth of the tallest fragment in the last
        #        printed line
        #   <tt>@baseline_y</tt>::
        #       the baseline of the current line
        #   <tt>@nothing_printed</tt>::
        #       set to true until something is printed, then false
        #   <tt>@everything_printed</tt>::
        #       set to false until everything printed, then true
        #
        # Returns any formatted text that was not printed
        #
        def wrap(array)
          initialize_wrap(array)

          stop = false
          until stop
            segments, metrics = lay_out_baseline

            if segments.nil?
              stop = true
            end

            next if stop
            next if segments.empty? && !@arranger.finished?

            print_segments(segments)
            stop = @single_line || @arranger.finished?
          end
          @text = @printed_lines.join("\n")
          @everything_printed = @arranger.finished?
          @arranger.unconsumed
        end

        private

        def normalize_exclusion_polygons(options)
          polygon_option = options[:exclusion_polygons] || options[:exclude_polygons]
          return [] if polygon_option.nil?

          if polygon_option.is_a?(Array) && polygon_option.first.is_a?(Array) &&
              polygon_option.first.first.is_a?(Array)
            polygons = polygon_option
          else
            polygons = [polygon_option]
          end

          polygons.map do |polygon|
            next polygon if polygon.is_a?(ExclusionPolygon)

            ExclusionPolygon.new(polygon)
          end
        end

        def lay_out_baseline
          metrics = next_line_metrics
          3.times do
            baseline = candidate_baseline(metrics)
            segments, actual_metrics = wrap_segments(baseline, metrics)

            unless fits_height?(baseline, actual_metrics)
              reconsume_segments(segments)
              if metrics_differ?(actual_metrics, metrics)
                metrics = actual_metrics
                next
              end
              return [nil, actual_metrics]
            end

            if metrics_differ?(actual_metrics, metrics)
              reconsume_segments(segments)
              metrics = actual_metrics
              next
            end

            @baseline_y = baseline
            @line_height = actual_metrics[:line_height]
            @ascender = actual_metrics[:ascender]
            @descender = actual_metrics[:descender]
            return [segments, actual_metrics]
          end

          [nil, metrics]
        end

        def wrap_segments(baseline, metrics)
          segments = []
          maximum_metrics = empty_metrics
          intervals = available_intervals(baseline, metrics)

          intervals.each do |left, right|
            break unless segments.empty? || !segments.last.paragraph_finished

            begin
              @line_wrap.wrap_line(
                document: @document,
                kerning: @kerning,
              width: right - left,
              arranger: @arranger,
              disable_wrap_by_char: @disable_wrap_by_char,
              strip_leading_whitespace: segments.empty?,
            )
            rescue Prawn::Errors::CannotFit
              reconsume_segments(segments)
              raise
            end

            fragments = retrieve_fragments
            segment = LineSegment.new(
              left,
              right - left,
              fragments.sum(&:width),
              fragments.sum(&:space_count),
              @line_wrap.paragraph_finished?,
              fragments,
            )
            segments << segment
            maximum_metrics = maximum_metrics(maximum_metrics, fragment_metrics(fragments))
          end

          maximum_metrics = metrics if segments.empty?
          [segments, maximum_metrics]
        end

        def retrieve_fragments
          fragments = []
          while fragment = @arranger.retrieve_fragment
            fragments << fragment
          end
          fragments
        end

        def reconsume_segments(segments)
          hashes = segments.flat_map do |segment|
            segment.fragments.map do |fragment|
              fragment.include_trailing_white_space!
              fragment.format_state.merge(text: fragment.text)
            end
          end
          @arranger.reconsume(hashes)
        end

        def available_intervals(baseline, metrics)
          intervals = [[@at[0], @at[0] + @width]]
          top = @at[1] + baseline + metrics[:ascender]
          bottom = @at[1] + baseline - metrics[:descender]

          @exclusion_polygons.each do |polygon|
            intervals = intervals.flat_map do |left, right|
              polygon.available_intervals(left, right, top, bottom)
            end
          end

          sort_intervals(intervals)
        end

        def sort_intervals(intervals)
          if @direction == :rtl
            intervals.sort_by { |left, _right| -left }
          else
            intervals.sort_by(&:first)
          end
        end

        def current_line_metrics
          {
            line_height: @document.font.height,
            ascender: @document.font.ascender,
            descender: @document.font.descender,
          }
        end

        def next_line_metrics
          hash = @arranger.unconsumed.find { |fragment| fragment[:text] != "\n" }
          return current_line_metrics if hash.nil?

          fragment = Prawn::Text::Formatted::Fragment.new(
            hash[:text], hash, @document
          )
          @document.save_font do
            @arranger.apply_font_settings(fragment) do
              return current_line_metrics
            end
          end
        end

        def empty_metrics
          { line_height: 0, ascender: 0, descender: 0 }
        end

        def fragment_metrics(fragments)
          {
            line_height: fragments.map(&:line_height).max || 0,
            ascender: fragments.map(&:ascender).max || 0,
            descender: fragments.map(&:descender).max || 0,
          }
        end

        def maximum_metrics(first, second)
          first.merge(second) { |_key, first_value, second_value|
            [first_value, second_value].max
          }
        end

        def metrics_differ?(first, second)
          first.any? { |key, value| (value - second[key]).abs > 1e-9 }
        end

        def candidate_baseline(metrics)
          if @baseline_y.zero?
            -metrics[:ascender]
          else
            @baseline_y - (@line_height + @leading)
          end
        end

        def fits_height?(baseline, metrics)
          (-baseline + metrics[:descender]) <= @height + 1e-4
        end

        def print_segments(segments)
          @nothing_printed = false
          printed_fragments = []
          segments.each do |segment|
            word_spacing = word_spacing_for_segment(segment)
            segment.fragments.each do |fragment|
              fragment.word_spacing = word_spacing
              if fragment.text == "\n"
                printed_fragments << "\n" if @printed_lines.last == ''
                next
              end
              printed_fragments << fragment.text
            end
            draw_segment(segment)
          end

          @printed_lines << printed_fragments.map { |s|
            s.dup.force_encoding(::Encoding::UTF_8)
          }.join
        end

        def draw_segment(segment)
          fragments = segment.fragments.reject { |fragment| fragment.text == "\n" }
          fragments.reverse! if @direction == :rtl
          accumulated_width = 0

          fragments.each do |fragment|
            fragment.default_direction = @direction
            format_and_draw_fragment(
              fragment,
              accumulated_width,
              segment.width,
              fragment.word_spacing,
              segment.left,
              segment.available_width,
            )
            accumulated_width += fragment.width
          end
        end

        def word_spacing_for_segment(segment)
          if @align == :justify && segment.space_count.positive? &&
              !segment.paragraph_finished
            (segment.available_width - segment.width) / segment.space_count
          else
            0
          end
        end

        def initialize_wrap(array)
          @text = nil
          @arranger.format_array = array

          # these values will depend on the maximum value within a given line
          @line_height = 0
          @descender = 0
          @ascender = 0
          @baseline_y = 0

          @printed_lines = []
          @nothing_printed = true
          @everything_printed = false
        end

        def format_and_draw_fragment(
          fragment, accumulated_width, line_width, word_spacing,
          line_left = @at[0], available_width = line_width
        )
          @arranger.apply_color_and_font_settings(fragment) do
            draw_fragment(
              fragment,
              accumulated_width,
              line_width,
              word_spacing,
              line_left,
              available_width,
            )
          end
        end
      end
    end
  end
end
