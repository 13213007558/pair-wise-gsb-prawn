# frozen_string_literal: true

require_relative 'line_wrap'
require_relative 'arranger'

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

          stop = false
          until stop
            if exclusion_zones
              stop = wrap_line_around_exclusions
            else
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
            end

            stop ||= @single_line || @arranger.finished?
          end
          @text = @printed_lines.join("\n")
          @everything_printed = @arranger.finished?
          @arranger.unconsumed
        end

        private

        # Exclusion zones to flow text around, or nil when there are none.
        # Overridden by the text box when the :exclusions option is used.
        #
        # @return [Prawn::Text::Formatted::ExclusionZones, nil]
        def exclusion_zones
          nil
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

        # Wrap a single visual line around the exclusion zones. The line may
        # be split into several horizontal segments that all share the same
        # baseline. Returns true when wrapping must stop.
        def wrap_line_around_exclusions
          # Seed the line metrics with the previous line (or the current
          # font) so the first band estimate is reasonable. The band is
          # refined below once the actual fragments are known, because mixed
          # font sizes and super/subscripts change the line height.
          ascender = @ascender.positive? ? @ascender : @document.font.ascender
          descender =
            @descender.positive? ? @descender : @document.font.descender
          line_height =
            @line_height.positive? ? @line_height : @document.font.height
          band_ascender = ascender
          band_descender = descender

          intervals = nil
          segments = nil
          iterations = 0
          loop do
            baseline = next_baseline(ascender, line_height)
            band_bottom = @at[1] + baseline - band_descender
            band_top = @at[1] + baseline + band_ascender
            new_intervals = exclusion_zones.available_intervals(
              band_bottom,
              band_top,
              @at[0],
              @at[0] + @width,
            )
            break if segments && new_intervals == intervals

            intervals = new_intervals
            repack_segments(segments) if segments
            segments = wrap_exclusion_segments(intervals)
            unless segments.empty?
              ascender = segments.map { |segment| segment[:ascender] }.max
              descender = segments.map { |segment| segment[:descender] }.max
              line_height = segments.map { |segment| segment[:line_height] }.max
              band_ascender =
                segments.map { |segment| segment[:band_ascender] }.max
              band_descender =
                segments.map { |segment| segment[:band_descender] }.max
            end
            iterations += 1
            break if iterations >= 10
          end

          @ascender = ascender
          @descender = descender
          @line_height = line_height

          if segments.nil? || segments.empty?
            # No interval on this line can hold a complete glyph. Push the
            # baseline down (bounded by the box height) instead of retrying
            # the same line forever.
            return true unless line_fits_height?

            move_baseline_down
            return false
          end

          unless line_fits_height?
            repack_segments(segments)
            return true
          end

          move_baseline_down
          print_segments(segments)
          false
        end

        # The baseline the next line would occupy given the estimated
        # ascender and line height.
        def next_baseline(ascender, line_height)
          if @baseline_y.zero?
            -ascender
          else
            @baseline_y - (line_height + @leading)
          end
        end

        # Whether a line with the current metrics fits in the remaining
        # height of the box.
        def line_fits_height?
          diff =
            if @baseline_y.zero?
              @ascender + @descender
            else
              @descender + @line_height + @leading
            end
          @baseline_y.abs + diff <= @height + 0.0001
        end

        # Wrap text into each available interval of the current line. Every
        # interval becomes at most one segment; segments share the baseline
        # and are filled in reading order.
        def wrap_exclusion_segments(intervals)
          return [] if intervals.empty?

          ordered = @direction == :rtl ? intervals.reverse : intervals
          full_width = [[@at[0], @at[0] + @width]]

          segments = []
          ordered.each do |seg_left, seg_right|
            break if @arranger.finished?

            seg_width = seg_right - seg_left
            begin
              @line_wrap.wrap_line(
                document: @document,
                kerning: @kerning,
                width: seg_width,
                arranger: @arranger,
                disable_wrap_by_char: @disable_wrap_by_char,
              )
            rescue Prawn::Errors::CannotFit
              # Behave like a plain too-narrow box when no exclusion is
              # actually in play; otherwise skip this interval.
              raise if ordered == full_width

              # restore the strings the failed wrap consumed
              @arranger.unconsumed.unshift(*@arranger.consumed)
              next
            end

            fragments = @arranger.fragments.dup
            segments << {
              left: seg_left,
              width: seg_width,
              fragments: fragments,
              line_width: @line_wrap.width,
              space_count: @line_wrap.space_count,
              paragraph_finished: @line_wrap.paragraph_finished?,
              line_height: @arranger.max_line_height,
              ascender: @arranger.max_ascender,
              descender: @arranger.max_descender,
              band_ascender:
                fragments.map { |f| f.ascender + f.y_offset }.max || 0,
              band_descender:
                fragments.map { |f| f.descender - f.y_offset }.max || 0,
            }
            # A newline ends the visual line; later intervals stay empty.
            break if fragments.any? { |fragment| fragment.text == "\n" }
          end
          segments
        end

        # Put the fragments of the given segments back into the arranger so
        # the line can be wrapped again (or left unprinted).
        def repack_segments(segments)
          hashes = segments.flat_map do |segment|
            segment[:fragments].map do |fragment|
              fragment.include_trailing_white_space!
              fragment.format_state.merge(text: fragment.text)
            end
          end
          @arranger.unconsumed.unshift(*hashes)
        end

        def print_segments(segments)
          @nothing_printed = false
          printed_fragments = []

          segments.each do |segment|
            word_spacing = word_spacing_for_segment(segment)
            accumulated_width = 0
            fragments = segment[:fragments]
            fragments = fragments.reverse if @direction == :rtl
            fragments.each do |fragment|
              fragment.word_spacing = word_spacing
              if fragment.text == "\n"
                printed_fragments << "\n" if @printed_lines.last == ''
                break
              end
              printed_fragments << fragment.text
              fragment.default_direction = @direction
              format_and_draw_fragment(
                fragment,
                segment_offset(segment) + accumulated_width,
                segment[:line_width],
                word_spacing,
              )
              accumulated_width += fragment.width
            end
          end

          @printed_lines << printed_fragments.map { |s|
            s.dup.force_encoding(::Encoding::UTF_8)
          }.join
        end

        # Horizontal offset of a segment relative to the box left edge,
        # taking alignment into account. Combined with the segment line width
        # this makes draw_fragment position the segment within its interval.
        def segment_offset(segment)
          base = segment[:left] - @at[0]
          case @align
          when :center
            base + ((segment[:width] - @width) * 0.5)
          when :right
            base + (segment[:width] - @width)
          when :justify
            @direction == :rtl ? base + (segment[:width] - @width) : base
          else
            base
          end
        end

        def word_spacing_for_segment(segment)
          if @align == :justify && segment[:space_count].positive? &&
              !segment[:paragraph_finished]
            (segment[:width] - segment[:line_width]) / segment[:space_count]
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

        def format_and_draw_fragment(fragment, accumulated_width, line_width, word_spacing)
          @arranger.apply_color_and_font_settings(fragment) do
            draw_fragment(
              fragment,
              accumulated_width,
              line_width,
              word_spacing,
            )
          end
        end
      end
    end
  end
end
