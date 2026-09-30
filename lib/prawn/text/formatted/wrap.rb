# frozen_string_literal: true

require_relative 'line_wrap'
require_relative 'optimal_line_break'
require_relative 'arranger'

module Prawn
  module Text
    module Formatted
      # Handles text wrapping for for formatted text.
      #
      # @private
      module Wrap
        attr_reader :line_adjustments

        def initialize(_array, options)
          @line_wrap = Prawn::Text::Formatted::LineWrap.new
          @arranger = Prawn::Text::Formatted::Arranger.new(
            @document,
            kerning: options[:kerning],
          )
          @disable_wrap_by_char = options[:disable_wrap_by_char]
          @line_break_strategy = options[:line_break_strategy] || :greedy
          @word_spacing_stretch = options[:word_spacing_stretch]
          @word_spacing_shrink = options[:word_spacing_shrink]
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
            # wrap before testing if enough height for this line because the
            # height of the highest fragment on this line will be used to
            # determine the line height
            @line_wrap.wrap_line(
              document: @document,
              kerning: @kerning,
              width: line_wrap_width,
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
          @line_adjustments << word_spacing if @line_break_strategy == :optimal

          @printed_lines << printed_fragments.map { |s|
            s.dup.force_encoding(::Encoding::UTF_8)
          }.join
        end

        def word_spacing_for_this_line
          if @line_break_strategy == :optimal
            return planned_line_adjustment.to_f
          end

          if @align == :justify && @line_wrap.space_count.positive? &&
              !@line_wrap.paragraph_finished?
            (available_width - @line_wrap.width) / @line_wrap.space_count
          else
            0
          end
        end

        def planned_line_adjustment
          @pending_line_adjustments.fetch(@line_adjustments.length, 0)
        end

        def line_wrap_width
          return available_width unless @line_break_strategy == :optimal

          planned_width = @pending_line_widths.fetch(@line_adjustments.length)
          [available_width, planned_width].max
        rescue IndexError
          available_width
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
            remove_planned_break if @line_break_strategy == :optimal
            false
          else
            true
          end
        end

        def initialize_wrap(array)
          @text = nil
          @line_adjustments = []
          @pending_line_adjustments = []
          @pending_line_widths = []

          array = layout_paragraphs_optimally(array) if @line_break_strategy == :optimal

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

        def layout_paragraphs_optimally(array)
          stretch = @word_spacing_stretch ||
            @document.width_of(' ', kerning: @kerning)
          shrink = @word_spacing_shrink || stretch * 0.5

          planner = Prawn::Text::Formatted::OptimalLineBreak.new(
            @document,
            width: available_width,
            kerning: @kerning,
            stretch: stretch,
            shrink: shrink,
            justify: @align == :justify,
            disable_wrap_by_char: @disable_wrap_by_char,
          )
          planned = planner.layout(array)
          @pending_line_adjustments = planner.lines.map { |line|
            line.adjustment.to_f
          }
          @pending_line_widths = planner.lines.map(&:width)
          planned
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

        def remove_planned_break
          if @arranger.unconsumed.first&.dig(:text) == "\n"
            @arranger.unconsumed.shift
          end
        end
      end
    end
  end
end
