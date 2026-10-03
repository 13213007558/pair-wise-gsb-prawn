# frozen_string_literal: true

require_relative 'fragment'

module Prawn
  module Text
    # Vertical (CJK) text layout.
    module Vertical
      # Vertical text box.
      #
      # Lays out text top to bottom, columns right to left (the traditional
      # CJK vertical writing mode), using the font's vertical metrics
      # (vhea/vmtx OpenType tables) and the vertical glyph variants the font
      # designates (GSUB vert/vrt2 features).
      #
      # Only OpenType fonts that contain vertical metrics tables can be
      # used. {Prawn::Errors::UnsupportedVerticalFont} is raised for any
      # other font.
      #
      # Latin-script characters are handled according to the rule declared
      # on the document ({Prawn::Text#vertical_latin_rule}) or the
      # `:latin_rule` option:
      #
      # - `:rotate` --- Latin runs are rotated 90 degrees clockwise
      #   (the so-called "sideways" rule).
      # - `:upright` --- Latin characters are set upright using the font's
      #   vertical metrics, like CJK characters.
      #
      # Generally, one would use the {Prawn::Text#vertical_text_box}
      # convenience method. However, using `Text::Vertical::Box.new` in
      # conjunction with `#render(dry_run: true)` enables one to do
      # calculations prior to placing text on the page.
      class Box
        # The text that was successfully printed (or, if `:dry_run` was
        # used, the text that would have been successfully printed).
        # @return [String]
        attr_reader :text

        # The upper left corner of the text box.
        # @return [Array(Number, Number)]
        attr_reader :at

        # The column pitch (horizontal advance) of the last column printed.
        # @return [Number]
        attr_reader :line_height

        # The leading used during printing.
        # @return [Number]
        attr_reader :leading

        # True if nothing printed (or, if `:dry_run` was used, nothing
        # would have been successfully printed).
        #
        # @return [Boolean]
        def nothing_printed?
          @nothing_printed
        end

        # True if everything printed (or, if `:dry_run` was used,
        # everything would have been successfully printed).
        #
        # @return [Boolean]
        def everything_printed?
          @everything_printed
        end

        # The height actually used during the previous {render}.
        #
        # @return [Number]
        def height
          @height_used || 0
        end

        # The width actually used during the previous {render}.
        #
        # @return [Number]
        def width
          @width_used || 0
        end

        # @param formatted_text [Array<Hash{Symbol => any}>]
        #   Formatted text, an array of hashes like the one
        #   {Prawn::Text::Formatted#formatted_text_box} accepts. The
        #   `:text`, `:font`, `:size`, `:styles`, `:color`,
        #   `:character_spacing`, `:link`, `:anchor`, and `:local` options
        #   are supported.
        # @param options [Hash{Symbol => any}]
        # @option options :document [Prawn::Document] Owning document.
        # @option options :at [Array(Number, Number)]
        #   (bounds top left corner) The upper left corner of the box.
        # @option options :width [Number] (bounds.right - at[0])
        #   The width of the box (the space available for columns).
        # @option options :height [Number] (default_height())
        #   The height of the box (the length of each column).
        # @option options :size [Number] (current font size)
        #   The font size to use.
        # @option options :style [Symbol] (current style)
        #   The style to use. The requested style must be part of the
        #   current font family.
        # @option options :kerning [Boolean]
        #   (value of document.default_kerning?) Whether or not to use
        #   kerning for rotated Latin runs.
        # @option options :align [:right, :center, :left] (:right)
        #   Alignment of the text block along the box width. Columns are
        #   laid out right to left, so by default the block sticks to the
        #   right edge of the box.
        # @option options :valign [:top, :center, :bottom] (:top)
        #   Alignment of the text block along the box height.
        # @option options :leading [Number]
        #   (value of document.default_leading) Additional space between
        #   columns.
        # @option options :character_spacing [Number] (0)
        #   The amount of space to add to or remove from the default
        #   character spacing.
        # @option options :mode [Symbol] (:fill)
        #   The text rendering mode.
        # @option options :overflow [:truncate, :shrink_to_fit, :expand]
        #   (:truncate) This controls the behavior when the amount of text
        #   exceeds the available space. `:expand` lets the box grow
        #   towards the left edge of the surrounding frame.
        # @option options :min_font_size [Number] (5)
        #   The minimum font size to use when `:overflow` is set to
        #   `:shrink_to_fit`.
        # @option options :latin_rule [:rotate, :upright]
        #   (value of document.vertical_latin_rule) How to set Latin-script
        #   characters.
        def initialize(formatted_text, options = {})
          @inked = false
          Prawn.verify_options(valid_options, options)
          options = options.dup

          @document = options[:document]
          @original_array = formatted_text

          @at = (
            options[:at] || [@document.bounds.left, @document.bounds.top]
          ).dup
          @width = options[:width] || (@document.bounds.right - @at[0])
          @height = options[:height] || default_height
          @align = options[:align] || :right
          @valign = options[:valign] || :top
          @leading = options[:leading] || @document.default_leading
          @character_spacing = options[:character_spacing] ||
            @document.character_spacing
          @mode = options[:mode] || @document.text_rendering_mode
          @mode = :fill if @mode == :unknown
          @overflow = options[:overflow] || :truncate
          @min_font_size = options[:min_font_size] || 5
          @latin_rule = options[:latin_rule] || @document.vertical_latin_rule
          @kerning =
            if options[:kerning].nil?
              @document.default_kerning?
            else
              options[:kerning]
            end
          @options = {
            size: options[:size],
            style: options[:style],
          }

          unless %i[right center left].include?(@align)
            raise ArgumentError,
              'align must be one of :right, :center or :left symbols'
          end
          unless %i[top center bottom].include?(@valign)
            raise ArgumentError,
              'valign must be one of :top, :center or :bottom symbols'
          end
          unless %i[rotate upright].include?(@latin_rule)
            raise ArgumentError,
              'latin_rule must be one of :rotate or :upright symbols'
          end

          if @overflow == :expand
            # Let the box grow towards the left edge of the innermost
            # non-stretchy frame, mirroring how horizontal boxes expand
            # towards the bottom.
            frame_left =
              frame.absolute_left - @document.bounds.absolute_left
            @width = @at[0] + @width - frame_left
            @overflow = :truncate
          end
        end

        # Render text to the document based on the settings defined in
        # constructor.
        #
        # @param flags [Hash{Symbol => any}]
        # @option flags :dry_run [Boolean] (false)
        #   Do not draw the text. Everything else is done.
        # @return [Array<Hash>]
        #   A formatted text array representing any text that did not print
        #   under the current settings.
        # @raise [Prawn::Errors::UnsupportedVerticalFont]
        #   If a used font doesn't provide vertical metrics.
        # @raise [Prawn::Errors::CannotFit]
        #   If the box is too narrow to fit any column of text.
        def render(flags = {})
          unprinted_text = []

          @document.save_font do
            @document.character_spacing(@character_spacing) do
              @document.text_rendering_mode(@mode) do
                process_options

                text = normalized_text

                @document.font_size(@font_size) do
                  shrink_to_fit(text) if @overflow == :shrink_to_fit
                  layout(text)
                  @inked = true unless flags[:dry_run]
                  draw_items
                  draw_annotations
                  @inked = false
                  unprinted_text = @unprinted
                end
              end
            end
          end

          unprinted_text
        end

        # @private
        def valid_options
          PDF::Core::Text::VALID_OPTIONS + %i[
            at
            height width
            align valign
            overflow min_font_size
            leading character_spacing
            mode
            document
            latin_rule
          ]
        end

        # A single upright glyph.
        # @private
        class Glyph
          attr_accessor :column, :y, :text_x, :text_y
          attr_reader :fragment, :char, :code, :advance, :origin_x,
            :origin_y, :substitutions, :source

          def initialize(fragment:, char:, source:)
            @fragment = fragment
            @char = char
            @source = source
            @code = char.ord

            font = fragment.font
            size = fragment.size

            @substitutions =
              if font.vertical_substitutions?
                glyph_id = font.vertical_substitute_for(@code)
                glyph_id ? { @code => glyph_id } : nil
              end

            @origin_x, @origin_y = font.vertical_origin_for(@code)
            @origin_x *= size / 1000.0
            @origin_y *= size / 1000.0

            @advance =
              (font.vertical_advance_for(@code) * size / 1000.0) +
              fragment.character_spacing
          end
        end

        # A run of Latin-script characters rotated 90 degrees clockwise
        # (the sideways rule).
        # @private
        class Run
          attr_accessor :column, :y, :origin_x, :origin_y
          attr_reader :fragment, :text, :advance, :source

          def initialize(fragment:, text:, source:, kerning:)
            @fragment = fragment
            @text = text
            @source = source

            font = fragment.font
            size = fragment.size

            @advance =
              font.compute_width_of(text, size: size, kerning: kerning) +
              (fragment.character_spacing * text.length)
          end
        end

        # An explicit column break.
        # @private
        class Break
          attr_reader :source

          def initialize(source:)
            @source = source
          end
        end

        # A column of vertical text.
        # @private
        class Column
          attr_accessor :pitch, :center_x
          attr_reader :items, :max_font_height, :used

          def initialize
            @items = []
            @max_font_height = 0
            @used = 0
          end

          def add(item, font_height)
            @items << item
            @max_font_height = [@max_font_height, font_height].max
            @used += item.advance
          end
        end

        # Comparison epsilon for fitting calculations.
        EPSILON = 0.0001

        private

        def process_options
          # must be performed within a save_font block because
          # document.process_text_options sets the font
          @document.process_text_options(@options)
          @font_size = @options[:size]
        end

        def normalized_text
          @original_array.map(&:dup)
        end

        # Decrease the font size until the text fits or the minimum font
        # size is reached.
        def shrink_to_fit(text)
          loop do
            layout(text)
            break if @everything_printed || @font_size <= @min_font_size

            @font_size = [@font_size - 0.5, @min_font_size].max
            @document.font_size = @font_size
          end
        end

        def layout(formatted)
          fragments = resolve_fragments(formatted)
          items = shape(fragments)
          place(items)
          finalize_columns
          @unprinted = compute_unprinted(formatted)
        end

        def resolve_fragments(formatted)
          formatted.map do |hash|
            style = font_style(hash[:styles])
            font_name = hash[:font]
            font_obj =
              if font_name || style != :normal
                unless @document.font.family
                  raise Prawn::Text::Formatted::Arranger::BadFontFamily
                end

                resolved = nil
                @document.font(
                  font_name || @document.font.family, style: style,
                ) do
                  resolved = @document.font
                end
                resolved
              else
                @document.font
              end

            verify_vertical_font!(font_obj)

            Fragment.new(
              font: font_obj,
              font_name: font_name,
              font_style: style,
              size: hash[:size] || @font_size,
              color: hash[:color],
              link: hash[:link],
              anchor: hash[:anchor],
              local: hash[:local],
              character_spacing:
                hash[:character_spacing] || @character_spacing,
              text:
                font_obj.normalize_encoding(hash[:text].to_s.dup)
                  .gsub(/\r\n?/, "\n"),
            )
          end
        end

        def verify_vertical_font!(font)
          if font.respond_to?(:vertical_metrics?) && font.vertical_metrics?
            return
          end

          raise Prawn::Errors::UnsupportedVerticalFont,
            'Vertical text layout requires an OpenType font with vertical ' \
              'metrics (vhea/vmtx tables), but the font ' \
              "#{font.name.inspect} does not provide them"
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

        # Is the character typeset sideways (rotated) per the Latin rule?
        def rotated_latin?(char)
          return false unless @latin_rule == :rotate

          code = char.ord
          # printable ASCII (except space) and Latin letters
          (0x21..0x7E).cover?(code) || (0x00C0..0x024F).cover?(code)
        end

        # Split fragments into glyph, run, and break items.
        def shape(fragments)
          items = []

          fragments.each_with_index do |fragment, fragment_index|
            chars = fragment.text.chars
            run_start = nil

            flush_run = lambda do |run_end|
              next if run_start.nil?

              items << Run.new(
                fragment: fragment,
                text: chars[run_start...run_end].join,
                source: [fragment_index, run_start, run_end],
                kerning: @kerning,
              )
              run_start = nil
            end

            chars.each_with_index do |char, char_index|
              if char == "\n"
                flush_run.call(char_index)
                items << Break.new(
                  source: [fragment_index, char_index, char_index + 1],
                )
              elsif rotated_latin?(char)
                run_start ||= char_index
              else
                flush_run.call(char_index)
                items << Glyph.new(
                  fragment: fragment,
                  char: char,
                  source: [fragment_index, char_index, char_index + 1],
                )
              end
            end

            flush_run.call(chars.length)
          end

          items
        end

        # Distribute items into columns, top to bottom, right to left.
        def place(items)
          @columns = [Column.new]
          column_used = 0.0
          @stop_source = nil

          items.each do |item|
            if item.is_a?(Break)
              @columns << Column.new
              column_used = 0.0
              next
            end

            if column_used + item.advance > @height + EPSILON
              if item.advance > @height + EPSILON
                # The item doesn't even fit in an empty column.
                @stop_source = item.source
                break
              end

              @columns << Column.new
              column_used = 0.0
            end

            item.column = @columns.last
            item.y = column_used
            font_height = item.fragment.font.height_at(item.fragment.size)
            @columns.last.add(item, font_height)
            column_used += item.advance
          end

          # Drop trailing empty columns left by trailing breaks.
          @columns.pop while @columns.length > 1 && @columns.last.items.empty?
        end

        # Trim columns that overflow the box width and compute final
        # coordinates of all items.
        def finalize_columns
          default_pitch = @document.font.height_at(@font_size)

          kept = []
          used_width = 0.0
          @columns.each do |column|
            column.pitch =
              if column.max_font_height.zero?
                default_pitch
              else
                column.max_font_height
              end

            column_width = column.pitch + (kept.empty? ? 0 : @leading)
            break if used_width + column_width > @width + EPSILON

            used_width += column_width
            kept << column
          end

          if kept.empty?
            raise Prawn::Errors::CannotFit,
              'Vertical text box is too narrow to fit any column of text'
          end

          if kept.length < @columns.length && @stop_source.nil?
            dropped = @columns[kept.length]
            first_dropped = dropped.items.first
            @stop_source =
              if first_dropped
                first_dropped.source
              else
                # an empty column: everything from the following column on
                following = @columns[(kept.length + 1)..]
                  .flat_map(&:items).first
                following&.source
              end
          end

          @columns = kept

          used_height = @columns.map(&:used).max || 0

          x_shift =
            case @align
            when :center then (@width - used_width) / 2.0
            when :left then @width - used_width
            else 0
            end
          y_shift =
            case @valign
            when :center then (@height - used_height) / 2.0
            when :bottom then @height - used_height
            else 0
            end

          column_right = @at[0] + @width - x_shift
          @columns.each do |column|
            column.center_x = column_right - (column.pitch / 2.0)
            column_right -= column.pitch + @leading

            column.items.each do |item|
              position_item(item, column, y_shift)
            end
          end

          @width_used = used_width
          @height_used = used_height
          @y_shift = y_shift
          @line_height = @columns.last.pitch
          @nothing_printed = @columns.all? { |column| column.items.empty? }
          @everything_printed = @stop_source.nil?
          @text = @columns.map { |column|
            column.items.map { |item|
              item.is_a?(Run) ? item.text : item.char
            }.join
          }.join("\n")
        end

        def position_item(item, column, y_shift)
          origin_y = @at[1] - item.y - y_shift

          case item
          when Glyph
            item.text_x = column.center_x - item.origin_x
            item.text_y = origin_y - item.origin_y
          when Run
            font = item.fragment.font
            ascender = descender = 0
            @document.font_size(item.fragment.size) do
              ascender = font.ascender
              descender = font.descender
            end
            item.origin_x = column.center_x - ((ascender - descender) / 2.0)
            item.origin_y = origin_y
          end
        end

        def compute_unprinted(formatted)
          return [] if @stop_source.nil?

          fragment_index, char_index = @stop_source

          formatted.each_with_index.filter_map do |hash, index|
            next if index < fragment_index

            unprinted = hash.dup
            unprinted[:text] =
              index == fragment_index ? hash[:text][char_index..] : hash[:text]
            unprinted unless unprinted[:text].nil? || unprinted[:text].empty?
          end
        end

        def draw_items
          return unless @inked

          @columns.each do |column|
            column.items.each do |item|
              apply_color_and_font_settings(item.fragment) do
                draw_item(item)
              end
            end
          end
        end

        def draw_item(item)
          case item
          when Glyph
            if item.substitutions
              @document.draw_text!(
                item.char,
                at: [item.text_x, item.text_y],
                vertical_substitutions: item.substitutions,
              )
            else
              @document.draw_text!(item.char, at: [item.text_x, item.text_y])
            end
          when Run
            @document.draw_text!(
              item.text,
              at: [item.origin_x, item.origin_y],
              rotate: -90,
              kerning: @kerning,
            )
          end
        end

        def apply_color_and_font_settings(fragment)
          if fragment.color
            original_fill_color = @document.fill_color
            original_stroke_color = @document.stroke_color
            @document.fill_color(*fragment.color)
            @document.stroke_color(*fragment.color)
            apply_font_settings(fragment) { yield }
            @document.stroke_color = original_stroke_color
            @document.fill_color = original_fill_color
          else
            apply_font_settings(fragment) { yield }
          end
        end

        def apply_font_settings(fragment)
          @document.character_spacing(fragment.character_spacing) do
            if fragment.font_name || fragment.font_style != :normal
              @document.font(
                fragment.font_name || @document.font.family,
                style: fragment.font_style,
              ) do
                @document.font_size(fragment.size) { yield }
              end
            else
              @document.font_size(fragment.size) { yield }
            end
          end
        end

        def draw_annotations
          return unless @inked

          @columns.each do |column|
            column
              .items
              .select { |item| annotated?(item.fragment) }
              .group_by(&:fragment)
              .each do |fragment, items|
                draw_fragment_annotations(fragment, segment_box(items))
              end
          end
        end

        def annotated?(fragment)
          fragment.link || fragment.anchor || fragment.local
        end

        # Bounding box of a run of items in a single column, in absolute
        # page coordinates.
        def segment_box(items)
          column = items.first.column
          left = column.center_x - (column.pitch / 2.0)
          right = column.center_x + (column.pitch / 2.0)

          top = items.map { |item| @at[1] - item.y - @y_shift }.max
          bottom =
            items.map { |item| @at[1] - item.y - @y_shift - item.advance }.min

          [
            left + @document.bounds.absolute_left,
            bottom + @document.bounds.absolute_bottom,
            right + @document.bounds.absolute_left,
            top + @document.bounds.absolute_bottom,
          ]
        end

        def draw_fragment_annotations(fragment, box)
          if fragment.link
            @document.link_annotation(
              box,
              Border: [0, 0, 0],
              A: {
                Type: :Action,
                S: :URI,
                URI: PDF::Core::LiteralString.new(fragment.link),
              },
            )
          end

          if fragment.anchor
            @document.link_annotation(
              box,
              Border: [0, 0, 0],
              Dest: fragment.anchor,
            )
          end

          return unless fragment.local

          @document.link_annotation(
            box,
            Border: [0, 0, 0],
            A: {
              Type: :Action,
              S: :Launch,
              F: PDF::Core::LiteralString.new(fragment.local),
              NewWindow: true,
            },
          )
        end

        # Returns the default height to be used if none is provided or if
        # the overflow option is set to :expand. If we are in a stretchy
        # bounding box, assume we can stretch to the bottom of the
        # innermost non-stretchy box.
        def default_height
          @at[1] + @document.bounds.absolute_bottom - frame.absolute_bottom
        end

        # The innermost non-stretchy bounding box.
        def frame
          frame = @document.bounds
          frame = frame.parent while frame.stretchy? && frame.parent
          frame
        end
      end
    end
  end
end
