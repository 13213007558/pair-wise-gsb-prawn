# frozen_string_literal: true

require_relative 'line_wrap'
require_relative 'arranger'
require_relative 'optimal_line_wrap'

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
          @line_breaks = options[:line_breaks] || :greedy
          @word_spacing_options = options[:word_spacing]
        end

        def preplan_optimal_line_breaks(array)
          planned = []
          paragraphs = split_paragraphs(array)
          paragraphs.each_with_index do |entries, paragraph_index|
            unless entries.empty?
              lines = Prawn::Text::Formatted::OptimalLineWrap.new(
                entries,
                document: @document,
                kerning: @kerning,
                width: available_width,
                justify: @align == :justify,
                disable_wrap_by_char: @disable_wrap_by_char,
                character_spacing: @character_spacing,
                word_spacing: @word_spacing_options,
              ).wrap
              planned.concat(lines.flatten)
            end
            if paragraph_index < paragraphs.length - 1
              planned << { text: "\n" }
            end
          end
          planned
        end

        def split_paragraphs(array)
          paragraphs = []
          current = []
          array.each do |hash|
            hash[:text].to_s.scan(/[^\n]+|\n/) do |part|
              if part == "\n"
                paragraphs << current
                current = []
              else
                current << hash.merge(text: part)
              end
            end
          end
          paragraphs << current
          paragraphs
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
          if @line_breaks == :optimal &&
              !array.any? { |hash| hash[:optimal_line_break] }
            array = preplan_optimal_line_breaks(array)
          end
          initialize_wrap(array)

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
            if merge_display_soft_hyphen?(fragments_this_line.last, fragment)
              printed_fragments.last << fragment.text
              fragments_this_line.last.merge_text(fragment)
            else
              fragments_this_line << fragment
            end
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

        def merge_display_soft_hyphen?(previous, fragment)
          previous &&
            previous.format_state[:display_soft_hyphen] &&
            fragment.text == Prawn::Text::SHY
        end

        def word_spacing_for_this_line
          if @align == :justify && @line_wrap.space_count.positive? &&
              !@line_wrap.paragraph_finished?
            planned_word_spacing ||
              (available_width - @line_wrap.width) / @line_wrap.space_count
          else
            0
          end
        end

        def planned_word_spacing
          @arranger.consumed.each do |fragment|
            if fragment[:optimal_line_break]
              return fragment[:optimal_word_spacing] || 0
            end
          end
          nil
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
