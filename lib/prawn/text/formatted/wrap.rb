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
        # Maximum number of times a single line is re-laid out around
        # exclusion zones before the band is skipped entirely. Re-layout
        # is needed because the height of the line (and thus the vertical
        # band that intersects the exclusion zones) depends on the fragments
        # that end up on the line, which in turn depends on the available
        # intervals.
        MAX_EXCLUSION_LAYOUT_ATTEMPTS = 4

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
            if exclusion_zones?
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

        # Whether exclusion zones are in effect. Overridden by the including
        # class when it supports exclusion zones.
        #
        # @return [Boolean]
        def exclusion_zones?
          false
        end

        # Lay out a single line of text around the exclusion zones.
        #
        # @return [Boolean] whether no more lines can be printed
        def wrap_line_around_exclusions
          # Provisionally wrap at the full width of the box to measure the
          # line. The actual height of the line determines the vertical band
          # used to intersect the exclusion zones.
          @line_wrap.wrap_line(
            document: @document,
            kerning: @kerning,
            width: available_width,
            arranger: @arranger,
            disable_wrap_by_char: @disable_wrap_by_char,
          )

          return true unless enough_height_for_this_line?

          intervals = exclusion_intervals(
            *line_vertical_span(@arranger.fragments, @ascender, @line_height),
          )

          if intervals == full_width_intervals
            move_baseline_down
            print_line
            return false
          end

          @arranger.repack_unretrieved

          segments = nil
          attempts = 0
          loop do
            segments = lay_out_line_segments(intervals)

            if segments.empty?
              # No interval on this line can hold even a single glyph. Move
              # the baseline down and try again on the next line. This
              # terminates because the height check above eventually runs out
              # of room.
              move_baseline_down
              return false
            end

            new_intervals = exclusion_intervals(*segments_vertical_span(segments))

            # The layout is safe to print when every interval it uses is
            # still available for the actual height of the line.
            break if intervals_covered?(intervals, new_intervals)

            if attempts >= MAX_EXCLUSION_LAYOUT_ATTEMPTS
              # The available intervals keep changing with the line height.
              # Rather than printing into the exclusion zones, skip this
              # band and try again on the next line.
              rollback_line_segments(segments)
              move_baseline_down
              return false
            end

            rollback_line_segments(segments)
            intervals = new_intervals
            attempts += 1
          end

          @line_height = segments.map { |segment| segment[:line_height] }.max
          @descender = segments.map { |segment| segment[:descender] }.max
          @ascender = segments.map { |segment| segment[:ascender] }.max

          move_baseline_down
          print_line_segments(segments)

          false
        end

        # Wrap the remaining text into each of the available horizontal
        # intervals, in reading order. Intervals that can not hold a single
        # glyph are skipped.
        #
        # @param intervals [Array<Array(Number, Number)>]
        # @return [Array<Hash>]
        def lay_out_line_segments(intervals)
          intervals = intervals.reverse if @direction == :rtl
          segments = []

          intervals.each do |segment_left, segment_right|
            break if @arranger.finished?

            segment_width = segment_right - segment_left
            next unless segment_width.positive?

            begin
              @line_wrap.wrap_line(
                document: @document,
                kerning: @kerning,
                width: segment_width,
                arranger: @arranger,
                disable_wrap_by_char: @disable_wrap_by_char,
              )
            rescue Prawn::Errors::CannotFit
              # This interval is too narrow to hold any part of the remaining
              # text. Put the text back and try the next interval.
              @arranger.rollback_line
              next
            end

            segments << {
              left: segment_left,
              width: segment_width,
              fragments: @arranger.fragments.dup,
              line_width: @line_wrap.width,
              space_count: @line_wrap.space_count,
              paragraph_finished: @line_wrap.paragraph_finished?,
              line_height: @arranger.max_line_height,
              descender: @arranger.max_descender,
              ascender: @arranger.max_ascender,
            }
            @arranger.fragments.replace([])

            break if @line_wrap.paragraph_finished?
          end

          segments
        end

        # Put the text of all segments back into the arranger so the line can
        # be laid out again with different intervals.
        #
        # @param segments [Array<Hash>]
        # @return [void]
        def rollback_line_segments(segments)
          @arranger.fragments.replace(
            segments.flat_map { |segment| segment[:fragments] },
          )
          @arranger.repack_unretrieved
        end

        # The vertical band (in bounding box coordinates) that the glyphs of
        # the given fragments would occupy if printed on the current line.
        # Takes super- and subscript offsets into account.
        #
        # @param fragments [Array<Prawn::Text::Formatted::Fragment>]
        # @param ascender [Number]
        # @param line_height [Number]
        # @return [Array(Number, Number)] top and bottom of the band
        def line_vertical_span(fragments, ascender, line_height)
          baseline =
            if @baseline_y.zero?
              -ascender
            else
              @baseline_y - (line_height + @leading)
            end

          top = fragments.map { |fragment|
            fragment.y_offset + fragment.ascender
          }.max
          bottom = fragments.map { |fragment|
            fragment.y_offset - fragment.descender
          }.min

          [@at[1] + baseline + top, @at[1] + baseline + bottom]
        end

        # The vertical band occupied by the glyphs of all segments of a line.
        #
        # @param segments [Array<Hash>]
        # @return [Array(Number, Number)] top and bottom of the band
        def segments_vertical_span(segments)
          fragments = segments.flat_map { |segment| segment[:fragments] }
          ascender = segments.map { |segment| segment[:ascender] }.max
          line_height = segments.map { |segment| segment[:line_height] }.max

          line_vertical_span(fragments, ascender, line_height)
        end

        def print_line_segments(segments)
          @nothing_printed = false
          printed_fragments = []

          segments.each do |segment|
            word_spacing = word_spacing_for_segment(segment)
            segment[:word_spacing] = word_spacing
            segment[:fragments].each do |fragment|
              fragment.word_spacing = word_spacing
              if fragment.text == "\n"
                printed_fragments << "\n" if @printed_lines.last == ''
                break
              end
              printed_fragments << fragment.text
            end
          end

          segments.each do |segment|
            accumulated_width = 0
            fragments = segment[:fragments]
            fragments.reverse! if @direction == :rtl
            fragments.each do |fragment|
              break if fragment.text == "\n"

              fragment.default_direction = @direction
              @segment_left = segment[:left]
              @segment_width = segment[:width]
              format_and_draw_fragment(
                fragment,
                accumulated_width,
                segment[:line_width],
                segment[:word_spacing],
              )
              accumulated_width += fragment.width
            end
          end

          @printed_lines << printed_fragments.map { |s|
            s.dup.force_encoding(::Encoding::UTF_8)
          }.join
        ensure
          @segment_left = nil
          @segment_width = nil
        end

        def word_spacing_for_segment(segment)
          if @align == :justify && segment[:space_count].positive? &&
              !segment[:paragraph_finished]
            (segment[:width] - segment[:line_width]) / segment[:space_count]
          else
            0
          end
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
