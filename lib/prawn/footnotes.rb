# frozen_string_literal: true

module Prawn
  # True page footnotes for flowing formatted text.
  module Footnotes
    Entry = Struct.new(
      :number,
      :fragments,
      :continuation,
      :text_options,
      keyword_init: true,
    )

    Chunk = Struct.new(
      :number,
      :fragments,
      :top,
      :bottom,
      keyword_init: true,
    )

    CannotFitFootnote = Class.new(StandardError)

    # Registers a footnote and returns a reference fragment for
    # {Text#formatted_text}.
    #
    # `continuation` may be a String, formatted-text Array, or a Proc called
    # with the footnote number.
    def footnote(text, continuation: nil, text_options: nil,
                 marker_options: nil, number: nil)
      number ||= footnote_layout.next_number
      fragments = text.is_a?(Array) ? text : [{ text: text }]
      footnote_layout.register(number, Entry.new(
        number: number,
        fragments: deep_copy(fragments),
        continuation: continuation,
        text_options: text_options,
      ))

      marker = {
        text: number.to_s,
        styles: [:superscript],
        footnote_number: number,
      }
      marker.merge!(marker_options) if marker_options
      marker
    end

    def formatted_text(array, options = {})
      return super unless array.any? { |fragment| fragment[:footnote_number] }

      footnote_layout.draw_text(array, options)
    end

    def start_new_page(options = {})
      return super if footnote_layout.bypassing?

      footnote_layout.draw_committed
      super
    ensure
      footnote_layout.begin_new_page
    end

    def render(*arguments)
      footnote_layout.flush_pending
      footnote_layout.draw_committed
      super
    end

    private

    def footnote_layout
      @footnote_layout ||= Layouter.new(self)
    end

    def deep_copy(value)
      case value
      when Array
        value.map { |item| deep_copy(item) }
      when Hash
        value.transform_values { |item| deep_copy(item) }
      else
        value
      end
    end

    # Lays out footnote-aware text one physical line at a time. Footnote text
    # is measured before body ink is committed, so a failed attempt can move
    # the anchor without leaving duplicate drawings behind.
    class Layouter
      LINE_OPTIONS = %i[
        kerning size character_spacing disable_wrap_by_char mode style
        align direction fallback_fonts leading overflow min_font_size
        valign rotate rotate_around
      ].freeze

      FOOTNOTE_GAP = 9

      def initialize(document)
        @document = document
        @registered = {}
        @committed = []
        @pending = []
        @reservation_bottom = nil
        @next_number = 1
        @bypassing = false
        @pending_carried = false
        @unreserved_margin_height = nil
        @original_margin_bottom = nil
        @drawn = false
      end

      def bypassing?
        @bypassing
      end

      def next_number
        number = @next_number
        @next_number += 1
        number
      end

      def register(number, entry)
        @registered[number] = entry
      end

      def begin_new_page
        @committed = []
        @reservation_bottom = nil
        @unreserved_margin_height = nil
        @original_margin_bottom = nil
        @drawn = false
      end

      def draw_committed
        return if @drawn

        @committed.each do |chunk|
          draw_chunk(chunk)
        end
        @drawn = true
      end

      def flush_pending
        while @pending.any?
          draw_committed
          open_new_page
          chunks = []
          begin
            chunks = pack_pending(
              limit_top: @document.margin_box.absolute_top
            )
          rescue CannotFitFootnote
            chunks = []
          end
          if chunks.empty?
            raise Prawn::Errors::FootnotesCannotFit,
              'footnote continuation does not fit on the page'
          end
          reserve_chunks(chunks)
        end
      end

      def draw_text(array, options)
        unless @document.bounds.equal?(@document.margin_box)
          raise ArgumentError,
            'footnotes are only supported in the document margin box'
        end

        options = options.dup
        final_gap = options.fetch(:final_gap, true)
        remaining = deep_copy(array)

        while remaining.any?
          line, remaining = next_physical_line(remaining, options)
          catch(:footnote_line_complete) do
            fit_line(line, options, final_gap)
          end
        end
      end

      private

      def deep_copy(value)
        case value
        when Array
          value.map { |item| deep_copy(item) }
        when Hash
          value.transform_values { |item| deep_copy(item) }
        else
          value
        end
      end

      def fit_line(line, options, final_gap)
        height = measure_line(line, options, final_gap)
        if @pending.any? && !@pending_carried
          snapshot = snapshot_page
          begin
            chunks = pack_pending(
              limit_top: @document.y - height - FOOTNOTE_GAP
            )
          rescue CannotFitFootnote
            restore_page(snapshot)
            chunks = []
          end

          if chunks.empty?
            draw_committed
            open_new_page
            chunks = pack_pending(
              limit_top: @document.margin_box.absolute_top
            )
          end

          reserve_chunks(chunks)
        end

        unless line_fits?(height)
          move_anchor_to_next_page(line, options, height)
        end

        snapshot = snapshot_page
        begin
          chunks = build_chunks_for_line(line, height)
        rescue CannotFitFootnote
          restore_page(snapshot)
          move_anchor_to_next_page(line, options, height)
          chunks = build_chunks_for_line(line, height)
        end

        reserve_chunks(chunks)
        render_line(line, options, height)
      end

      def move_anchor_to_next_page(line, options, height)
        if first_body_line?
          unless line_fits?(height)
            raise Prawn::Errors::FootnotesCannotFit,
              'not enough total height for the anchor and footnote'
          end

          snapshot = snapshot_page
          begin
            build_chunks_for_line(line, height)
          rescue CannotFitFootnote
            raise Prawn::Errors::FootnotesCannotFit,
              'footnote does not fit on the same page as its anchor'
          ensure
            restore_page(snapshot)
          end
        end

        draw_committed
        open_new_page
        fit_line(line, options, options.fetch(:final_gap, true))
        throw(:footnote_line_complete)
      end

      def open_new_page
        @bypassing = true
        @document.start_new_page
      ensure
        @bypassing = false
        begin_new_page
      end

      def next_physical_line(array, options)
        box = dry_box(array, options, single_line: true)
        remaining = box.render(dry_run: true)
        line = box.printed_fragments
        if line.empty? && remaining.any? { |fragment| fragment[:text] == "\n" }
          line = [{ text: "\n" }]
        end
        [line, remaining]
      end

      def measure_line(line, options, final_gap)
        box = dry_box(line, options, single_line: true)
        box.render(dry_run: true)
        height = box.height
        height += box.line_gap + box.leading if final_gap
        height
      end

      def render_line(line, options, height)
        box = Text::Formatted::Box.new(
          deep_copy(line),
          box_options(line, options).merge(single_line: true),
        )
        box.render
        @document.y -= height
      end

      def dry_box(source, options, extra_options)
        Text::Formatted::Box.new(
          deep_copy(source),
          box_options(source, options).merge(extra_options),
        )
      end

      def box_options(_source, options)
        selected = options.slice(*LINE_OPTIONS)
        selected[:document] = @document
        selected[:height] = 1_000_000
        selected[:width] = @document.bounds.width
        selected[:at] = [
          @document.bounds.left,
          @document.y - @document.bounds.absolute_bottom,
        ]
        selected
      end

      def line_fits?(height)
        height <= available_body_height + 1e-9
      end

      def available_body_height
        [@document.y - reservation_bottom, 0].max
      end

      def build_chunks_for_line(line, line_height)
        chunks = []
        marker_numbers(line).each do |number|
          entry = @registered.fetch(number)
          chunks.concat(pack_entry(
            entry,
            initial: true,
            limit_top: @document.y - line_height - FOOTNOTE_GAP,
          ))
        end
        chunks
      end

      def pack_pending(limit_top:)
        entries = @pending
        @pending = []
        @pending_carried = true
        entries.flat_map do |entry|
          pack_entry(
            entry,
            initial: false,
            limit_top: limit_top,
          )
        end
      end

      def pack_entry(entry, initial:, limit_top:)
        bottom = next_chunk_bottom
        available_height = limit_top - bottom
        raise CannotFitFootnote if available_height <= 0

        source = initial ? initial_source(entry) : continuation_source(entry)
        box = Text::Formatted::Box.new(
          deep_copy(source),
          note_options(entry).merge(
            document: @document,
            at: [
              @document.margin_box.absolute_left,
              bottom + available_height,
            ],
            width: @document.margin_box.width,
            height: available_height,
            overflow: :truncate,
          ),
        )
        remaining = box.render(dry_run: true)
        raise CannotFitFootnote if box.nothing_printed?

        unless box.everything_printed?
          pending_entry = entry.dup
          pending_entry.fragments = remaining
          @pending << pending_entry
        end

        chunk = Chunk.new(
          number: entry.number,
          fragments: box.printed_fragments,
          top: bottom + box.height,
          bottom: bottom,
        )
        @committed << chunk
        [chunk]
      end

      def initial_source(entry)
        [{ text: "#{entry.number}. " }] + deep_copy(entry.fragments)
      end

      def continuation_source(entry)
        continuation = entry.continuation
        marker =
          if continuation.nil? || continuation == true
            [{ text: "#{entry.number} (cont.) ", styles: [:italic] }]
          elsif continuation.respond_to?(:call)
            formatted_fragments(continuation.call(entry.number))
          else
            formatted_fragments(continuation)
          end
        marker + deep_copy(entry.fragments)
      end

      def formatted_fragments(value)
        if value.is_a?(Array)
          value
        else
          [{ text: value.to_s }]
        end
      end

      def note_options(entry)
        {
          size: [@document.font_size - 2, 1].max,
          leading: @document.default_leading,
        }.merge(entry.text_options || {})
      end

      def marker_numbers(line)
        line.filter_map { |fragment| fragment[:footnote_number] }.uniq
      end

      def next_chunk_bottom
        if @committed.empty?
          original_margin_bottom
        else
          @committed.map(&:top).max + FOOTNOTE_GAP
        end
      end

      def reserve_chunks(chunks)
        return if chunks.empty?

        new_reservation_top =
          chunks.map(&:top).max + FOOTNOTE_GAP
        new_bottom = new_reservation_top - original_margin_bottom
        delta = new_bottom - (@reservation_bottom || 0)
        return if delta <= 0

        @reservation_bottom = new_bottom
        apply_reservation
      end

      def snapshot_page
        [@committed.length, deep_copy(@pending), @reservation_bottom,
         @pending_carried]
      end

      def restore_page(snapshot)
        committed_length, @pending, @reservation_bottom,
          @pending_carried = snapshot
        @committed = @committed.first(committed_length)
        apply_reservation
      end

      def first_body_line?
        (@document.y - @document.bounds.absolute_top).abs < 1e-9
      end

      def draw_chunk(chunk)
        entry = @registered.fetch(chunk.number)
        @document.canvas do
          @document.formatted_text_box(
            deep_copy(chunk.fragments),
            note_options(entry).merge(
              at: [
                @document.margin_box.absolute_left,
                chunk.top,
              ],
              width: @document.margin_box.width,
              height: chunk.top - chunk.bottom,
              overflow: :truncate,
            ),
          )
        end
      end

      def reservation_bottom
        original_margin_bottom + (@reservation_bottom || 0)
      end

      def apply_reservation
        full_height = @unreserved_margin_height ||
          @document.margin_box.height
        @unreserved_margin_height ||= full_height
        @document.margin_box.instance_variable_set(
          :@height,
          full_height - (@reservation_bottom || 0),
        )
      end

      def original_margin_bottom
        @original_margin_bottom ||= @document.margin_box.absolute_bottom
      end
    end
  end
end
