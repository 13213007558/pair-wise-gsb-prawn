# frozen_string_literal: true

require_relative 'line_wrap'
require_relative 'arranger'
require_relative '../bidi'

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
          @bidi = options[:bidi]
          # Paragraph direction for the bidirectional algorithm. When the
          # user did not explicitly request a direction, it is determined
          # per line from the first strong character.
          @bidi_paragraph_direction = options[:direction]
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
            print_line_bidi(fragments_this_line, word_spacing)
          else
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
          end

          @printed_lines << printed_fragments.map { |s|
            s.dup.force_encoding(::Encoding::UTF_8)
          }.join
        end

        # Print a line in bidirectional mode.
        #
        # The logical text of the whole line is run through the Unicode
        # Bidirectional Algorithm (line-level rules are re-applied after
        # wrapping). Fragments are split at bidi run boundaries so that
        # links, callbacks and styles follow the visual segments. Pieces
        # are drawn in logical order at their visual positions so that
        # text extraction keeps the logical order.
        def print_line_bidi(fragments, word_spacing)
          return if fragments.empty?

          line_text = fragments.map(&:text).join
          char_fragment = []
          fragments.each_with_index do |fragment, index|
            fragment.text.length.times { char_fragment << index }
          end

          runs = Prawn::Text::Bidi.visual_runs(
            line_text,
            base_direction: @bidi_paragraph_direction,
          )

          # Split runs at fragment boundaries into drawable pieces.
          pieces = []
          runs.each_with_index do |run, run_index|
            run[:start].upto(run[:start] + run[:length] - 1) do |char_index|
              fragment_index = char_fragment[char_index]
              piece = pieces.last
              if piece.nil? ||
                  piece[:run_index] != run_index ||
                  piece[:fragment_index] != fragment_index
                pieces << {
                  run_index: run_index,
                  fragment_index: fragment_index,
                  level: run[:level],
                  start: char_index,
                  text: +'',
                }
                piece = pieces.last
              end
              piece[:text] << line_text[char_index]
            end
          end

          # Build fragment objects for the pieces and measure them.
          pieces.each do |piece|
            source = fragments[piece[:fragment_index]]
            format_state = source.format_state.dup
            # The source fragment text was already processed; pieces must
            # not be stripped again.
            format_state.delete(:exclude_trailing_white_space)
            fragment = Prawn::Text::Formatted::Fragment.new(
              piece[:text],
              format_state,
              @document,
            )
            fragment.word_spacing = word_spacing
            @arranger.apply_font_settings(fragment) do
              fragment.width = measure_bidi_piece(piece)
              fragment.line_height = source.line_height
              fragment.descender = source.descender
              fragment.ascender = source.ascender
            end
            fragment.bidi_level = piece[:level]
            piece[:fragment] = fragment
          end

          # Assign visual x offsets, keeping the mapping from logical
          # characters to glyph positions.
          offset = 0
          runs.each_with_index do |run, run_index|
            run_pieces = pieces.select { |p| p[:run_index] == run_index }
            run_pieces.reverse! if run[:level].odd?
            run_pieces.each do |piece|
              piece[:x] = offset
              offset += piece[:fragment].width
            end
          end

          # Draw in logical order so text extraction stays logical.
          line_width = offset
          pieces.sort_by { |p| p[:start] }.each do |piece|
            format_and_draw_fragment(
              piece[:fragment],
              piece[:x],
              line_width,
              word_spacing,
            )
          end
        end

        # Width of a bidi piece. Odd-level (right-to-left) pieces are drawn
        # cluster by cluster, so they are measured the same way.
        def measure_bidi_piece(piece)
          if piece[:level].odd?
            piece[:text].scan(/\X/).sum { |cluster|
              @document.width_of(cluster, kerning: false)
            }
          else
            @document.width_of(piece[:text], kerning: @kerning)
          end
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
