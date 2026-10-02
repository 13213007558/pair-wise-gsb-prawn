# frozen_string_literal: true

module Prawn
  # Page-bottom footnotes for flowing text.
  #
  # Long reports can register footnotes that are collected at the bottom of
  # the page on which their reference marker ends up. A footnote is tied to
  # its marker: the footnote always *starts* on the page where the marker is
  # printed. If reserving room for a footnote pushes the line holding its
  # marker onto the next page, the footnote is re-attributed to that page as
  # well (the previous page is left short).
  #
  # Footnotes are used through formatted text arrays:
  #
  # @example
  #   pdf.formatted_text([
  #     { text: 'Body text' },
  #     pdf.footnote_ref('First footnote.'),
  #     { text: ' more text' },
  #     pdf.footnote_ref('Second footnote.'),
  #   ])
  #
  # {Footnotes#footnote_ref} registers the footnote and returns a marker
  # fragment (a superscript number) to splice into the fragment array.
  # Numbers are assigned in registration order and never skip, regardless of
  # how the layout settles.
  #
  # Layout notes:
  #
  # * Multiple footnotes on one page are stacked in marker order.
  # * A footnote taller than the space left below its marker is split: the
  #   part that fits is printed at the bottom of the page and the remainder
  #   continues at the bottom of the following page(s). A footnote taller
  #   than a whole page keeps flowing until it is fully printed.
  # * Footnotes are only split between lines. If a footnote contains a
  #   single unbreakable chunk taller than one page (for example one huge
  #   line), {Prawn::Errors::CannotFit} is raised instead of looping
  #   forever.
  # * The space reserved for footnotes on a page never shrinks once it has
  #   grown during layout. This keeps pagination stable: a marker pushed off
  #   a page by its own footnote stays pushed, so pages do not oscillate.
  # * Reserving space is computed with dry-run text boxes only. Trial
  #   layouts never draw, never run fragment callbacks or
  #   +:draw_text_callback+, and never add objects to the PDF store; the
  #   body text is rendered exactly once.
  #
  # Limitations:
  #
  # * Footnotes are placed by the flowing text methods ({Prawn::Text#text}
  #   and {Prawn::Text#formatted_text}) at the bottom of the page margin
  #   box. Content drawn with other primitives (images, tables, bounding
  #   boxes, columns) does not participate in footnote layout.
  # * A footnote whose marker fragment is never rendered is silently
  #   dropped.
  module Footnotes
    # Default font size for footnote text.
    FOOTNOTE_FONT_SIZE = 8

    # Vertical space reserved at the top of the footnote area for the
    # separator rule and the gap below it.
    FOOTNOTE_RULE_SPACE = 6

    # Length of the footnote separator rule, as a fraction of the margin
    # box width.
    FOOTNOTE_RULE_LENGTH = 0.25

    # Registers a footnote and returns its marker fragment.
    #
    # Splice the returned hash into a formatted text array where the
    # reference marker should appear:
    #
    # @example
    #   pdf.formatted_text([
    #     { text: 'See the appendix' },
    #     pdf.footnote_ref('Appendix C, page 12.'),
    #     { text: ' for details.' },
    #   ])
    #
    # The footnote text is printed at the bottom of the page on which the
    # marker ends up, numbered in registration order.
    #
    # @param note_text [String] footnote content
    # @param options [Hash{Symbol => any}]
    # @option options :size [Number] (FOOTNOTE_FONT_SIZE)
    #   Font size used to render the footnote at the bottom of the page.
    # @return [Hash] a formatted text fragment for the marker
    def footnote_ref(note_text, options = {})
      @footnote_counter = (@footnote_counter || 0) + 1
      id = @footnote_counter
      footnote_registry[id] = {
        text: note_text,
        size: options.fetch(:size, FOOTNOTE_FONT_SIZE),
        height_cache: {},
      }
      { text: id.to_s, styles: [:superscript], footnote_id: id }
    end

    # Renders pending footnotes for the page being left.
    #
    # @private
    def start_new_page(options = {})
      finalize_page_footnotes
      super
    end

    # Flushes footnotes for the final page(s) before rendering.
    #
    # @private
    def render(*arguments)
      finalize_page_footnotes
      until footnote_continuation.empty?
        start_new_page
        finalize_page_footnotes
      end
      super
    end

    private

    # Footnote-aware replacement for the flowing text box filler. When no
    # footnotes are in flight this defers to the original implementation.
    #
    # @private
    def fill_formatted_text_box(text, options)
      return super unless footnotes_layout_active?

      merge_text_box_positioning_options(options)
      available = options[:height]

      reserve = footnote_reserve_for(text, options, available)
      @page_footnote_reserve = reserve
      options[:height] = available - reserve

      box = Text::Formatted::Box.new(text, options)
      remaining_text = box.render
      @no_text_printed = box.nothing_printed?
      @all_text_printed = box.everything_printed?

      self.y -= box.height

      if @final_gap || (options[:single_line] && !@all_text_printed)
        self.y -= box.line_gap + box.leading
      end

      assign_page_footnotes(text, remaining_text)

      remaining_text
    end

    # Whether any footnote state requires the footnote-aware layout path.
    #
    # @private
    def footnotes_layout_active?
      !footnote_continuation.empty? ||
        !page_footnote_ids.empty? ||
        !footnote_registry.empty?
    end

    # Computes the footnote area height for the current page. The reserve
    # only grows within a page (never oscillates) and is bounded so at
    # least one body line always fits.
    #
    # @private
    def footnote_reserve_for(text, options, available)
      capacity = [available - footnote_min_body_height, 0].max
      reserve = [footnote_base_reserve, capacity].min
      return reserve if pending_footnote_ids_empty?

      loop do
        trial = Text::Formatted::Box.new(
          text,
          options.merge(height: [available - reserve, 0].max),
        )
        remaining = trial.render(dry_run: true)
        ids = printed_footnote_ids(text, remaining)
        break if ids.empty?

        desired = footnote_total_reserve(
          @footnote_continuation_height.to_f + page_footnote_height +
            ids.sum { |id| footnote_height(id) },
        )
        if ids.any? { |id| footnote_oversized?(id) }
          # A footnote that cannot fit on any single page is split right
          # below its marker instead of pushing the marker off the page.
          keep = available -
            height_through_last_marker(text, remaining, options)
          desired = [desired, keep].min
        end
        desired = [desired, capacity].min
        break if desired <= reserve

        reserve = desired
      end
      reserve
    end

    # Reserve implied by footnotes already bound to the current page
    # (continuations from the previous page plus footnotes assigned by
    # earlier text boxes on this page).
    #
    # @private
    def footnote_base_reserve
      footnote_total_reserve(
        @footnote_continuation_height.to_f + page_footnote_height,
      )
    end

    # Adds the separator rule space when any footnote content is present.
    #
    # @private
    def footnote_total_reserve(content_height)
      content_height.positive? ? content_height + FOOTNOTE_RULE_SPACE : 0
    end

    # Height of one line of body text; the layout always leaves room for
    # at least one body line so pagination keeps making progress.
    #
    # @private
    def footnote_min_body_height
      font.height
    end

    # Whether the footnote is taller than one full page of body area and
    # therefore must be split across pages.
    #
    # @private
    def footnote_oversized?(id)
      @margin_box &&
        footnote_height(id) + FOOTNOTE_RULE_SPACE >
          @margin_box.height - footnote_min_body_height
    end

    # Ids of pending footnotes whose markers appear in the given fragments,
    # in order of appearance.
    #
    # @private
    def footnote_ids_in(fragments)
      ids = []
      fragments.each do |fragment|
        id = fragment[:footnote_id]
        next if id.nil? || footnote_assigned_ids.include?(id)
        next unless footnote_registry.key?(id)

        ids << id unless ids.include?(id)
      end
      ids
    end

    # Ids of pending footnotes whose markers were printed: they are part of
    # the laid out text but did not overflow into the remaining text.
    #
    # @private
    def printed_footnote_ids(text, remaining)
      unprinted = footnote_ids_in(remaining)
      footnote_ids_in(text).reject { |id| unprinted.include?(id) }
    end

    # Moves footnotes whose markers were printed by the just-rendered box
    # from the pending registry to the current page.
    #
    # @private
    def assign_page_footnotes(text, remaining)
      printed_footnote_ids(text, remaining).each do |id|
        footnote_assigned_ids << id
        page_footnote_ids << id
        @page_footnote_height = page_footnote_height + footnote_height(id)
      end
    end

    # Height of the body text up to and including the line holding the
    # last pending marker in the given consumed fragments.
    #
    # @private
    def height_through_last_marker(text, remaining, options)
      printed = text[0...(text.length - remaining.length)] || []
      index = printed.rindex { |fragment| fragment[:footnote_id] }
      return 0 unless index

      measure_fragments_height(
        printed[0..index],
        options[:width],
        gap: false,
      )
    end

    # Measured height of a single footnote (marker label + text), cached
    # per margin width.
    #
    # @private
    def footnote_height(id)
      entry = footnote_registry[id]
      width = footnote_area_width
      entry[:height_cache][width] ||=
        measure_fragments_height(footnote_fragments(id), width)
    end

    # Lays out fragments in a throwaway dry-run box and returns the height
    # they would occupy. Never draws and never adds PDF objects.
    #
    # @private
    def measure_fragments_height(fragments, width, gap: true)
      box = Text::Formatted::Box.new(
        fragments,
        document: self,
        at: [0, 0],
        width: width,
        height: 10_000_000,
      )
      box.render(dry_run: true)
      height = box.height
      height += box.line_gap + box.leading if gap
      height
    end

    # Fragments rendering one footnote: its number label, its text, and a
    # paragraph break.
    #
    # @private
    def footnote_fragments(id)
      entry = footnote_registry[id]
      size = entry[:size]
      [
        { text: "#{id}. ", size: size },
        { text: entry[:text], size: size },
        { text: "\n", size: size },
      ]
    end

    # Width of the footnote area (the page margin box).
    #
    # @private
    def footnote_area_width
      @margin_box ? @margin_box.width : bounds.width
    end

    # Prints the footnotes bound to the current page at the bottom of the
    # margin box and carries any overflow to the next page. Runs at most
    # once per page.
    #
    # @private
    def finalize_page_footnotes
      return if @finalizing_footnotes
      return if page_footnote_ids.empty? && footnote_continuation.empty?
      return if @margin_box.nil?
      return if @footnotes_finalized_page.equal?(state.page)

      @finalizing_footnotes = true
      @footnotes_finalized_page = state.page

      fragments = footnote_continuation +
        page_footnote_ids.flat_map { |id| footnote_fragments(id) }
      reserve = [@page_footnote_reserve || 0, @margin_box.height].min

      float do
        bounding_box(
          [@margin_box.absolute_left, @margin_box.absolute_bottom + reserve],
          width: @margin_box.width,
          height: reserve,
        ) do
          draw_footnote_rule(reserve)
          box = Text::Formatted::Box.new(
            fragments,
            document: self,
            at: [0, reserve - FOOTNOTE_RULE_SPACE],
            width: @margin_box.width,
            height: reserve - FOOTNOTE_RULE_SPACE,
          )
          remaining = box.render

          if box.nothing_printed? &&
              reserve >= @margin_box.height - footnote_min_body_height
            raise Prawn::Errors::CannotFit,
              'Footnote content does not fit on a single page. Footnotes ' +              'are only split between lines; unbreakable content taller ' +              'than one page cannot be rendered.'
          end

          @footnote_continuation = remaining
          @footnote_continuation_height =
            if remaining.empty?
              0
            else
              measure_fragments_height(remaining, @margin_box.width)
            end
        end
      end

      page_footnote_ids.each { |id| footnote_registry.delete(id) }
      @page_footnote_ids = []
      @page_footnote_height = 0
      @page_footnote_reserve =
        footnote_total_reserve(@footnote_continuation_height.to_f)
    ensure
      @finalizing_footnotes = false
    end

    # Draws the separator rule above the footnote area.
    #
    # @private
    def draw_footnote_rule(reserve)
      save_graphics_state do
        line_width(0.5)
        horizontal_line(
          0,
          bounds.width * FOOTNOTE_RULE_LENGTH,
          at: reserve - (FOOTNOTE_RULE_SPACE / 2.0),
        )
      end
    end

    # @private
    def footnote_registry
      @footnote_registry ||= {}
    end

    # @private
    def footnote_assigned_ids
      @footnote_assigned_ids ||= Set.new
    end

    # @private
    def page_footnote_ids
      @page_footnote_ids ||= []
    end

    # @private
    def page_footnote_height
      @page_footnote_height ||= 0
    end

    # @private
    def footnote_continuation
      @footnote_continuation ||= []
    end

    # @private
    def pending_footnote_ids_empty?
      footnote_registry.keys.all? { |id| footnote_assigned_ids.include?(id) }
    end
  end
end
