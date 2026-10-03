# frozen_string_literal: true

require_relative 'vertical_run'

module Prawn
  module Text
    module Formatted
      # Top-to-bottom, right-to-left text layout.
      #
      # @private
      module VerticalWrap
        def wrap(array)
          return super unless @writing_mode == :vertical_rl

          initialize_vertical_wrap(array)
          process_vertical_formatted_text(array)
          finalize_vertical_wrap
        end

        private

        def initialize_vertical_wrap(_array)
          if @rotate != 0
            raise ArgumentError,
              'vertical writing does not support the :rotate option'
          end
          vertical_font_data!
          @unprinted_vertical_text = []
          @vertical_runs = []
          @printed_text = +''
          @column_index = 0
          @vertical_y = @at[1]
          @used_width = 0
          @column_width = 0
          @column_started = false
          @column_has_runs = false
          @nothing_printed = true
          @everything_printed = false
        end

        def process_vertical_formatted_text(formatted_text)
          formatted_text.each do |hash|
            remaining = process_vertical_hash(hash)
            @unprinted_vertical_text << remaining unless remaining.nil?
          end
        end

        def process_vertical_hash(hash)
          remaining = nil
          apply_vertical_fragment_font(hash) do
            remaining_text = +''
            hash[:text].each_char do |char|
              if place_vertical_character(char, hash)
                @printed_text << char
              else
                remaining_text << char
              end
            end
            remaining = if remaining_text.empty?
              nil
            else
              hash.merge(text: remaining_text)
            end
          end
          remaining
        end

        def apply_vertical_fragment_font(hash)
          font = hash[:font]
          size = hash[:size]
          style = font_style(hash[:styles])
          @document.character_spacing(
            hash[:character_spacing] || @character_spacing,
          ) do
            if font || style != :normal
              @document.font(font || @document.font.family, style: style) do
                apply_vertical_size(size) { yield }
              end
            else
              apply_vertical_size(size) { yield }
            end
          end
        end

        def apply_vertical_size(size)
          if size.nil?
            yield
          else
            @document.font_size(size) { yield }
          end
        end

        def font_style(styles)
          styles = Array(styles)
          if styles.include?(:bold) && styles.include?(:italic)
            :bold_italic
          elsif styles.include?(:bold)
            :bold
          elsif styles.include?(:italic)
            :italic
          else
            :normal
          end
        end

        def place_vertical_character(char, hash)
          if char == "\n"
            advance_to_next_vertical_column
            return true
          end

          unless fits_vertical_height?(char)
            if fits_box_width?(char)
              return false unless advance_to_next_vertical_column
            else
              return false
            end
          end

          run = build_vertical_run(char, hash)
          draw_vertical_run(run)
          @vertical_runs << run
          @nothing_printed = false
          @column_started = true
          @column_has_runs = true
          @vertical_y -= run.advance
          @column_width = [@column_width, run.width].max
          true
        end

        def fits_vertical_height?(char)
          vertical_font_data!
          glyph_id = vertical_glyph_id(char)
          rotated = rotated_vertical_glyph?(char)
          advance = vertical_advance(glyph_id, rotated)
          @vertical_y - advance >= @at[1] - @height - 1e-9
        end

        def fits_box_width?(char)
          glyph_id = vertical_glyph_id(char)
          rotated = rotated_vertical_glyph?(char)
          width = rotated ? horizontal_glyph_width(glyph_id) : vertical_column_width(glyph_id)
          fits_box_width = if @column_started
            @used_width + [@column_width, width].max <= @width + 1e-9
          else
            projected_column_width = [@column_width, width].max
            projected_used_width = if @column_index.zero? && @used_width.zero?
              projected_column_width
            else
              @used_width + @leading + projected_column_width
            end
            projected_used_width <= @width + 1e-9
          end
          fits_box_width
        end

        def advance_to_next_vertical_column
          return false unless @column_has_runs
          next_used_width = @used_width + @column_width
          next_used_width += @leading if @column_index.positive?
          return false if next_used_width > @width + 1e-9

          @used_width += @column_width
          @used_width += @leading unless @used_width.zero?
          @column_index += 1
          @column_width = 0
          @column_started = false
          @column_has_runs = false
          @vertical_y = @at[1]
          true
        end

        def build_vertical_run(char, hash)
          glyph_id = vertical_glyph_id(char)
          rotated = rotated_vertical_glyph?(char)
          advance = vertical_advance(glyph_id, rotated)
          width = rotated ? horizontal_glyph_width(glyph_id) : vertical_column_width(glyph_id)
          height = rotated ? horizontal_glyph_width(glyph_id) : advance
          x = vertical_x(glyph_id, width, rotated)
          y = vertical_baseline_y(glyph_id, rotated, advance)
          VerticalRun.new(
            char,
            hash,
            glyph_id,
            rotated,
            x,
            y,
            width,
            height,
            advance,
            @document,
          )
        end

        def vertical_font_data!
          unless @document.font.respond_to?(:vertical_data)
            raise Prawn::Errors::UnsupportedVerticalFont,
              'vertical writing requires an embedded TTF/OTF font with vhea '
              'and vmtx tables'
          end
          @document.font.vertical_data
        rescue Prawn::Fonts::VerticalData::UnsupportedFont
          raise Prawn::Errors::UnsupportedVerticalFont,
            'vertical writing requires an embedded TTF/OTF font with vhea '
            'and vmtx tables'
        end

        def vertical_glyph_id(char)
          data = vertical_font_data!
          original = data.glyph_id(char)
          if original.nil? || original.zero?
            raise Prawn::Errors::CannotFit,
              "font does not contain U+#{format('%04X', char.codepoints.first)}"
          end
          data.substitute(original)
        end

        def rotated_vertical_glyph?(char)
          !cjk_vertical_character?(char)
        end

        def cjk_vertical_character?(char)
          code = char.codepoints.first
          code >= 0x2E80 ||
            (0x3000..0x303F).cover?(code) ||
            (0xFF00..0xFFEF).cover?(code)
        end

        def vertical_scale
          @document.font_size / @document.font.ttf.header.units_per_em.to_f
        end

        def vertical_advance(glyph_id, rotated)
          width = if rotated
            horizontal_glyph_width(glyph_id)
          else
            vertical_font_data!.advance_height(glyph_id) * vertical_scale
          end
          width + @document.character_spacing
        end

        def vertical_column_width(glyph_id)
          @document.font.ttf.horizontal_metrics.for(glyph_id).advance_width *
            vertical_scale
        end

        def horizontal_glyph_width(glyph_id)
          @document.font.ttf.horizontal_metrics.for(glyph_id).advance_width *
            vertical_scale
        end

        def vertical_x(glyph_id, run_width, rotated)
          right = @at[0] + @width - @used_width
          if rotated
            right - run_width
          else
            right - run_width / 2.0
          end
        end

        def vertical_baseline_y(glyph_id, rotated, advance)
          if rotated
            @vertical_y - advance / 2.0
          else
            @vertical_y -
              vertical_font_data!.vertical_origin_y(glyph_id) * vertical_scale
          end
        end

        def draw_vertical_run(run)
          return unless @inked

          draw_fragment_underlays(run.fragment)
          @document.font.draw_vertical_glyph(
            @document,
            run.glyph_id,
            run.x,
            run.y,
            run.rotated,
          )
          draw_fragment_overlays(run.fragment)
        end

        def finalize_vertical_wrap
          @text = @printed_text
          @everything_printed = @unprinted_vertical_text.empty?
          @line_height = @document.font.height
          @ascender = @document.font.ascender
          @descender = @document.font.descender
          @baseline_y = -@ascender
          @vertical_used_height = [[0, @at[1] - @vertical_y].max, @height].min
          @unprinted_vertical_text
        end
      end
    end
  end
end
