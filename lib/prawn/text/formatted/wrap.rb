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
        def initialize(_array, options)
          @line_wrap = Prawn::Text::Formatted::LineWrap.new
          @arranger = Prawn::Text::Formatted::Arranger.new(
            @document,
            kerning: options[:kerning],
          )
          @disable_wrap_by_char = options[:disable_wrap_by_char]
          @line_break = options[:line_break] || :greedy
          @hyphen_penalty = options[:hyphen_penalty]
          @consecutive_hyphen_penalty =
            options[:consecutive_hyphen_penalty]
          @planned_lines = []
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
          plan_paragraph if optimal_line_breaking?

          stop = false
          until stop
            # wrap before testing if enough height for this line because the
            # height of the highest fragment on this line will be used to
            # determine the line height
            if optimal_line_breaking?
              wrap_prepared_line
            else
              @line_wrap.wrap_line(
                document: @document,
                kerning: @kerning,
                width: available_width,
                arranger: @arranger,
                disable_wrap_by_char: @disable_wrap_by_char,
              )
            end

            if enough_height_for_this_line?
              move_baseline_down
              print_line
            else
              stop = true
            end

            stop ||= @single_line ||
              (@planned_lines.empty? && @arranger.finished?)
          end

          if optimal_line_breaking?
            @planned_lines.each_with_index do |line, index|
              fragments = line.fragments.map(&:dup)
              if index.zero? && @arranger.consumed.any?
                first_fragment = fragments.first
                if first_fragment && first_fragment[:text] != "\n" &&
                    !first_fragment[:text].start_with?(/\s/)
                  first_fragment[:text] = " #{first_fragment[:text]}"
                end
              end
              @arranger.append_unconsumed(fragments)
            end
          end
          @text = @printed_lines.join("\n")
          @everything_printed = @arranger.finished?
          @arranger.unconsumed
        end

        private

        def optimal_line_breaking?
          @line_break == :optimal
        end

        def plan_paragraph
          @planned_lines = []

          until @arranger.finished?
            planner = Prawn::Text::Formatted::OptimalLineBreak.new(
              @document,
              @arranger,
              kerning: @kerning,
              width: available_width,
              justify: @align == :justify,
              disable_wrap_by_char: @disable_wrap_by_char,
              hyphen_penalty: @hyphen_penalty,
              consecutive_hyphen_penalty:
                @consecutive_hyphen_penalty,
            )
            paragraph = planner.paragraph
            @planned_lines.concat(paragraph.lines)
          end
        end

        def wrap_prepared_line
          line = @planned_lines.shift
          if line.nil?
            @arranger.initialize_line
            @arranger.finalize_line
            @accumulated_width = 0
            @space_count = 0
            return ''
          end

          @arranger.prepare_line(
            line.fragments,
            paragraph_finished: line.paragraph_finished,
          )
          @line_wrap.wrap_prepared_line(
            document: @document,
            kerning: @kerning,
            arranger: @arranger,
          )
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
