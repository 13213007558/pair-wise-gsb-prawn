# frozen_string_literal: true

require_relative 'line_wrap'
require_relative 'arranger'
require_relative 'exclusion_polygons'

module Prawn
  module Text
    module Formatted
      # Handles text wrapping for for formatted text.
      #
      # @private
      module Wrap
        def initialize(_array, options)
          @line_wrap = Prawn::Text::Formatted::LineWrap.new
          @arranger = Prawn::Text::Formatted::Arranger.new(
            @document,
            kerning: options[:kerning],
          )
          @disable_wrap_by_char = options[:disable_wrap_by_char]
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
          return wrap_around_exclusions if @exclusion_polygons

          stop = false
          until stop
            # wrap before testing if enough height for this line because the
            # height of the highest fragment on this line will be used to
            # determine the line height
            @line_wrap.wrap_line(
              document: @document,
              kerning: @kerning,
              width: available_width,
              arranger: @arranger,
              disable_wrap_by_char: @disable_wrap_by_char,
            )

            if enough_height_for_this_line?
              move_baseline_down
              print_line
            else
              stop = true
            end

            stop ||= @single_line || @arranger.finished?
          end
          @text = @printed_lines.join("\n")
          @everything_printed = @arranger.finished?
          @arranger.unconsumed
        end

        private

        def wrap_around_exclusions
          stop = false

          until stop
            baseline_before_line = @baseline_y
            snapshot = @arranger.snapshot_unconsumed
            metrics = current_font_metrics
            segments = nil
            regions = nil

            loop do
              @baseline_y = baseline_before_line
              @arranger.restore_unconsumed(snapshot)
              apply_line_metrics(metrics)
              first_line = baseline_before_line.zero?
              if baseline_before_line.zero?
                @baseline_y = -metrics[:ascender]
              else
                @baseline_y =
                  baseline_before_line - @line_height - @leading
              end
              regions = available_regions(metrics)

              if regions.empty?
                unless enough_height_for_metrics?(metrics)
                  stop = true
                  break
                end

                next_baseline = @baseline_y
                @baseline_y = baseline_before_line
                skip_line_band(metrics, first_line, next_baseline)
                segments = :skipped
                break
              end

              begin
                segments = layout_segments(ordered_regions(regions))
              rescue Prawn::Errors::CannotFit
                candidate_baseline = @baseline_y
                @baseline_y = baseline_before_line
                skip_line_band(metrics, first_line, candidate_baseline)
                segments = :skipped
              end
              actual_metrics = arranger_line_metrics

              if actual_metrics.values.any?(&:zero?)
                actual_metrics = metrics
              end

              if metrics_dominate?(metrics, actual_metrics)
                break
              end

              metrics = merge_metrics(metrics, actual_metrics)
            end

            next if segments == :skipped

            if stop
              @baseline_y = baseline_before_line
              break
            end

            unless enough_height_for_metrics?(metrics)
              @arranger.repack_unretrieved
              stop = true
              break
            end

            print_segments(segments)
            stop ||= @single_line || @arranger.finished?
          end

          @text = @printed_lines.join("\n")
          @everything_printed = @arranger.finished?
          @arranger.unconsumed
        end

        def layout_segments(regions)
          snapshot = @arranger.snapshot_unconsumed
          segments = []
          region_index = 0
          failed_regions = []

          loop do
            available_regions = regions.reject do |region|
              failed_regions.include?(region)
            end

            if region_index >= available_regions.length
              @arranger.restore_unconsumed(snapshot)
              raise Prawn::Errors::CannotFit
            end

            region = available_regions[region_index]
            begin
              @line_wrap.wrap_line(
                document: @document,
                kerning: @kerning,
                width: region_width(region),
                arranger: @arranger,
                disable_wrap_by_char: @disable_wrap_by_char,
                continue_line: segments.any?,
              )
            rescue Prawn::Errors::CannotFit
              failed_regions << region
              @arranger.restore_unconsumed(snapshot)
              segments = []
              region_index = 0
              next
            end

            segments << @arranger.segments.last.merge(region: region)
            region_index += 1

            break if @line_wrap.paragraph_finished?
            break if @arranger.finished?
            break if region_index >= regions.length
          end

          segments
        end

        def print_segments(segments)
          @nothing_printed = false
          printed_fragments = []
          paragraph_finished = @line_wrap.paragraph_finished?

          segments.each do |segment|
            region = segment[:region]
            word_spacing = word_spacing_for_segment(segment, region, paragraph_finished)
            segment_width =
              segment[:width] + word_spacing * segment[:space_count]
            drawable_fragments = []

            segment[:fragments].each do |fragment|
              fragment.word_spacing = word_spacing
              if fragment.text == "\n"
                printed_fragments << "\n" if @printed_lines.last == ''
                break
              end

              printed_fragments << fragment.text
              drawable_fragments << fragment
            end

            drawable_fragments.reverse! if @direction == :rtl
            accumulated_width = 0
            drawable_fragments.each do |fragment|
              fragment.default_direction = @direction
              format_and_draw_fragment(
                fragment,
                accumulated_width,
                segment_width,
                word_spacing,
                region_left: region.first,
                region_width: region_width(region),
              )
              accumulated_width += fragment.width
            end
          end

          @arranger.fragments.replace([])
          @printed_lines << printed_fragments.map { |s|
            s.dup.force_encoding(::Encoding::UTF_8)
          }.join
        end

        def word_spacing_for_segment(segment, region, paragraph_finished)
          if @align == :justify && !paragraph_finished &&
              segment[:space_count].positive?
            width = region_width(region)
            [0, width - segment[:width]].max / segment[:space_count]
          else
            0
          end
        end

        def current_font_metrics
          {
            line_height: @document.font.height,
            ascender: @document.font.ascender,
            descender: @document.font.descender,
          }
        end

        def ordered_regions(regions)
          if @direction == :rtl
            regions.sort_by { |left, _right| -left }
          else
            regions
          end
        end

        def metrics_dominate?(candidate, actual)
          candidate.all? { |key, value| value + 0.0001 >= actual[key] }
        end

        def merge_metrics(first, second)
          first.keys.each_with_object({}) do |key, metrics|
            metrics[key] = [first[key], second[key]].max
          end
        end

        def line_metrics
          {
            line_height: @line_height,
            ascender: @ascender,
            descender: @descender,
          }
        end

        def arranger_line_metrics
          {
            line_height: @arranger.max_line_height,
            ascender: @arranger.max_ascender,
            descender: @arranger.max_descender,
          }
        end

        def apply_line_metrics(metrics)
          @line_height = metrics[:line_height]
          @ascender = metrics[:ascender]
          @descender = metrics[:descender]
        end

        def skip_line_band(metrics, first_line, candidate_baseline)
          advance = @line_height + @leading
          @baseline_y =
            if first_line
              -metrics[:ascender] - advance
            else
              candidate_baseline - advance
            end
        end

        def enough_height_for_metrics?(metrics)
          diff =
            if @baseline_y.zero?
              metrics[:ascender] + metrics[:descender]
            else
              metrics[:descender] + metrics[:line_height] + @leading
            end
          @baseline_y.abs + diff <= @height + 0.0001
        end

        def available_regions(metrics)
          left = @at[0]
          right = left + @width
          top = @at[1] + @baseline_y + metrics[:ascender]
          bottom = @at[1] + @baseline_y - metrics[:descender]

          @exclusion_polygons.intervals(left, right, top, bottom)
        end

        def region_width(region)
          region.last - region.first
        end

        def print_line
          @nothing_printed = false
          printed_fragments = []
          fragments_this_line = []

          word_spacing = word_spacing_for_this_line
          @arranger.fragments.each do |fragment|
            fragment.word_spacing = word_spacing
            if fragment.text == "\n"
              printed_fragments << "\n" if @printed_lines.last == ''
              break
            end
            printed_fragments << fragment.text
            fragments_this_line << fragment
          end
          @arranger.fragments.replace([])

          accumulated_width = 0
          fragments_this_line.reverse! if @direction == :rtl
          fragments_this_line.each do |fragment_this_line|
            fragment_this_line.default_direction = @direction
            format_and_draw_fragment(
              fragment_this_line,
              accumulated_width,
              @line_wrap.width,
              word_spacing,
            )
            accumulated_width += fragment_this_line.width
          end

          @printed_lines << printed_fragments.map { |s|
            s.dup.force_encoding(::Encoding::UTF_8)
          }.join
        end

        def word_spacing_for_this_line
          if @align == :justify && @line_wrap.space_count.positive? &&
              !@line_wrap.paragraph_finished?
            (available_width - @line_wrap.width) / @line_wrap.space_count
          else
            0
          end
        end

        def enough_height_for_this_line?
          @line_height = @arranger.max_line_height
          @descender = @arranger.max_descender
          @ascender = @arranger.max_ascender
          diff =
            if @baseline_y.zero?
              @ascender + @descender
            else
              @descender + @line_height + @leading
            end
          require_relatived_total_height = @baseline_y.abs + diff
          if require_relatived_total_height > @height + 0.0001
            # no room for the full height of this line
            @arranger.repack_unretrieved
            false
          else
            true
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
          fragment, accumulated_width, line_width, word_spacing, **options
        )
          @arranger.apply_color_and_font_settings(fragment) do
            draw_fragment(
              fragment,
              accumulated_width,
              line_width,
              word_spacing,
              **options,
            )
          end
        end
      end
    end
  end
end
