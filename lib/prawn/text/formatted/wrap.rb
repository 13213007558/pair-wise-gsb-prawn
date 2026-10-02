# frozen_string_literal: true

require_relative 'line_wrap'
require_relative 'arranger'
require_relative 'visual_fragment'

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
            bidi: options[:bidi],
          )
          @disable_wrap_by_char = options[:disable_wrap_by_char]
          @bidi = options[:bidi]
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
            fragments_this_line << fragment
          end
          @arranger.fragments.replace([])

          if @bidi
            logical_line = fragments_this_line.reject { |fragment|
              fragment.text == "\n"
            }.map(&:text).join
            if fragments_this_line.empty?
              @printed_lines << printed_fragments.map { |s|
                s.dup.force_encoding(::Encoding::UTF_8)
              }.join
              return
            end
            base_level = Prawn::Text::Bidi.base_level(logical_line, @paragraph_direction)
            @direction = base_level.zero? ? :ltr : :rtl
            @align ||= @direction == :rtl ? :right : :left
            @bidi_positions ||= {}
            @bidi_positions[logical_line] ||=
              Prawn::Text::Bidi.new(logical_line, @direction).visual_positions
            print_bidi_line(
              fragments_this_line,
              printed_fragments,
              word_spacing,
              logical_line,
              @bidi_positions[logical_line],
            )
            return
          end

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

        def print_bidi_line(fragments, printed_fragments, word_spacing, logical_text, bidi_positions)
          characters = []
          fragments.each do |fragment|
            fragment.text.each_char.with_index do |char, fragment_index|
              type = Prawn::Text::Bidi.character_type(char.codepoints.first)
              next if Prawn::Text::Bidi::INVISIBLE_TYPES.include?(type)
              positions = characters.length
              width = @arranger.character_width(char, fragment)
              characters << {
                char: char,
                fragment: fragment,
                fragment_index: fragment_index,
                width: width,
                index: positions,
              }
            end
          end

          positions = bidi_positions.map(&:dup)
          last_logical_index = positions.length - 1
          positions.each do |position|
            source = characters[position.logical_index]
            position.base_width = source[:width]
            position.width = source[:width] + source[:fragment].character_spacing +
              (position.char == ' ' ? word_spacing : 0)
            position.fragment = source[:fragment]
            position.fragment_index = source[:fragment_index]
            position.trailing = position.logical_index == last_logical_index
          end

          visual_fragments = positions.slice_when do |left, right|
            left.fragment != right.fragment ||
              left.level.odd? != right.level.odd?
          end.map do |group|
            Prawn::Text::Formatted::VisualFragment.from_positions(
              group.first.fragment, group, @document
            )
          end

          line_width = visual_fragments.sum(&:width)
          accumulated_width = 0
          @bidi_line_started = nil
          visual_fragments.each do |visual_fragment|
            visual_fragment.word_spacing = word_spacing
            format_and_draw_bidi_fragment(
              visual_fragment,
              accumulated_width,
              line_width,
              word_spacing,
              logical_text,
            )
            accumulated_width += visual_fragment.width
          end
          end_bidi_logical_text if @inked
          @bidi_line_started = nil
          @printed_lines << Prawn::Text::Bidi.logical_text_without_controls(logical_text)
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
          @bidi_positions = {}
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

        def format_and_draw_bidi_fragment(fragment, accumulated_width, line_width, _word_spacing, logical_text)
          @arranger.apply_color_and_font_settings(fragment) do
            draw_bidi_fragment(
              fragment,
              accumulated_width,
              line_width,
              logical_text,
            )
          end
        end
      end
    end
  end
end
