# frozen_string_literal: true

module Prawn
  # Page-local footnotes that reserve body space before an anchor is drawn.
  module Footnotes
    DEFAULT_GAP = 8
    DEFAULT_SEPARATOR_GAP = 8
    DEFAULT_SEPARATOR_WIDTH_RATIO = 1.to_r / 3

    Footnote = Struct.new(:number, :fragments, :options, :started, keyword_init: true)
    Chunk = Struct.new(
      :number, :fragments, :height, :options, :continues, :end_marker,
      keyword_init: true
    )

    # Maintains stable footnote numbering and page-local footnote chunks.
    class Manager
      def initialize(document, options = {})
        @document = document
        @options = options
        @next_number = 0
        @active = []
        @chunks = []
        @notes = {}
        @reserved_height = 0
        @prepared_page = document.page_number
        @drawn_page = nil
        @page_bottom = document.margin_box.absolute_bottom
      end

      def add(text, options = {})
        note = Footnote.new(
          number: next_number!,
          fragments: normalize_fragments(text),
          options: @options.merge(options),
          started: false,
        )
        @notes[note.number] = copy_note(note)
        place(note)
        note.number
      end

      def add_anchor(text, options = {})
        add(text, options.merge(anchor_height: options.fetch(:anchor_height) {
          @document.font.height
        }))
      end

      def anchor_drawn(number, page_number)
        return unless @pending_anchor == number

        @anchor_page = page_number
      end

      def render_anchor_block(number, block)
        @pending_anchor = number
        @anchor_page = nil
        block.call(number)
        @anchor_page || @document.page_number
      ensure
        @pending_anchor = nil
      end

      def render_anchor_block_with_retry(number, block)
        2.times do |attempt|
          snapshot = anchor_snapshot
          @defer_finish = true
          page = render_anchor_block(number, block)
          if page == snapshot[:page_number]
            @defer_finish = false
            finish_page
            return page
          end

          restore_anchor_snapshot(snapshot)

          if attempt == 1
            @defer_finish = false
            raise Prawn::Errors::FootnoteCannotFit,
              "footnote #{number} cannot fit with its anchor"
          end

          requeue_note(number, snapshot[:active])
          @document.start_new_page
        end
      end

      def finish_page
        return if @defer_finish

        return if @drawn_page == @document.page_number

        draw_current_page
        @drawn_page = @document.page_number
      end

      def finish_document
        prepare_current_page
        while @active.any?
          finish_page
          advance_page
        end
        finish_page
      end

      private

      def next_number!
        @next_number += 1
      end

      def place(note)
        prepare_current_page
        sources = @active + [note]
        capacity = available_capacity(note.options)

        if fit?(sources, capacity)
          commit(sources, capacity)
          return
        end

        finish_page
        advance_page

        while @active.any? && !fit?(@active + [note], available_capacity(note.options))
          if @active.one? && !fit?(@active, body_gap)
            raise Prawn::Errors::FootnoteCannotFit,
              "footnote #{@active.first.number} is too large for the page"
          end

          finish_page
          advance_page
        end

        sources = @active + [note]
        unless fit?(sources, available_capacity(note.options))
          raise Prawn::Errors::FootnoteCannotFit,
            "footnote #{note.number} cannot fit with its anchor"
        end

        commit(sources, available_capacity(note.options))
      end

      def prepare_current_page
        return if @prepared_page == @document.page_number &&
          @drawn_page.nil?

        sources = @active.map { |note| copy_note(note, started: true) }
        @page_bottom = @document.margin_box.absolute_bottom
        @chunks = []
        @reserved_height = 0
        @prepared_page = @document.page_number
        @drawn_page = nil
        @active = sources

        commit(@active, body_gap) if @active.any?
      end

      def anchor_snapshot
        {
          page_number: @document.page_number,
          page_count: @document.page_count,
          page_stream: @document.page.content.stream
            .instance_variable_get(:@stream)&.dup,
          graphic_state: @document.page.graphic_state.dup,
          font: @document.font,
          font_size: @document.font_size,
          character_spacing: @document.character_spacing,
          y: @document.y,
          bounds: @document.bounds.deep_copy,
          margin_box: @document.margin_box.deep_copy,
          chunks: @chunks.map(&:dup),
          active: @active.map { |note| copy_note(note) },
          reserved_height: @reserved_height,
          page_bottom: @page_bottom,
          prepared_page: @prepared_page,
          drawn_page: @drawn_page,
        }
      end

      def restore_anchor_snapshot(snapshot)
        delete_created_pages(snapshot[:page_count])
        stream = @document.state.pages[snapshot[:page_number] - 1].content
        pdf_stream = stream.stream
        pdf_stream << '' if pdf_stream.empty?
        pdf_stream.instance_variable_get(:@stream).replace(snapshot[:page_stream])
        pdf_stream.instance_variable_set(:@filtered_stream, nil)
        @document.state.page.instance_variable_set(
          :@stack,
          PDF::Core::GraphicStateStack.new(snapshot[:graphic_state]),
        )
        @document.go_to_page(snapshot[:page_number])
        @document.font(snapshot[:font].name, size: snapshot[:font_size])
        @document.instance_variable_set(
          :@character_spacing,
          snapshot[:character_spacing],
        )
        @document.y = snapshot[:y]
        @document.bounds = Document::BoundingBox.restore_deep_copy(
          snapshot[:bounds], @document
        )
        @document.margin_box = Document::BoundingBox.restore_deep_copy(
          snapshot[:margin_box], @document
        )
        @chunks = snapshot[:chunks].map(&:dup)
        @active = snapshot[:active].map { |note| copy_note(note) }
        @reserved_height = snapshot[:reserved_height]
        @page_bottom = snapshot[:page_bottom]
        @prepared_page = snapshot[:prepared_page]
        @drawn_page = snapshot[:drawn_page]
      end

      def delete_created_pages(original_count)
        (@document.page_count - original_count).times do
          @document.delete_page(-1)
        end
      end

      def advance_page
        @chunks = []
        @reserved_height = 0
        @document.start_new_page
        prepare_current_page
      end

      def requeue_note(number, pending_notes)
        @active =
          if pending_notes.any?
            pending_notes.map { |note| copy_note(note) }
          else
            note = @notes.fetch(number) do
              raise Prawn::Errors::FootnoteCannotFit,
                "footnote #{number} cannot be repositioned"
            end
            [copy_note(note)]
          end
        @chunks = []
        @reserved_height = 0
      end

      def body_gap
        @document.y - @document.margin_box.absolute_bottom
      end

      def available_capacity(options)
        anchor_height = options.fetch(:anchor_height, @document.font.height)
        body_gap - anchor_height
      end

      def fit?(notes, capacity)
        layout(notes, capacity)
        true
      rescue Prawn::Errors::CannotFit
        false
      end

      def commit(notes, capacity)
        result = layout(notes, capacity)
        completed = @chunks.reject do |chunk|
          notes.any? { |note| note.number == chunk.number }
        end
        @active = result[:pending]
        @chunks = completed + result[:chunks]
        @reserved_height = reserved_height_for(@chunks)
        @document.margin_box.reserve_footnote_height(
          @reserved_height,
          @page_bottom,
        )
        result
      end

      def layout(original_notes, capacity)
        notes = original_notes.map { |note| copy_note(note) }
        available = capacity - separator_height
        raise Prawn::Errors::CannotFit if available.negative?

        minima = calculate_minima(notes)
        chunks = []
        pending = []
        trailing_gap = 0

        notes.each_with_index do |note, index|
          suffix = suffix_minimum(notes, minima, index + 1)
          height = available - trailing_gap - suffix
          minimum = minima[index]
          raise Prawn::Errors::CannotFit if height < minimum

          fragments = labelled_fragments(note)
          leftover, actual_height = render_dry(fragments, height)
          continues = !leftover.empty?

          if continues
            fragments, leftover, actual_height =
              chunk_with_continuation(note, height, minimum)
            continues = !leftover.empty?
            raise Prawn::Errors::CannotFit if leftover.empty?
          end

          chunks << Chunk.new(
            number: note.number,
            fragments: fragments,
            height: actual_height,
            options: note.options,
            continues: continues,
            end_marker: continues ? continuation_marker(note, :continues) : [],
          )
          note.fragments = leftover
          note.started = true

          if leftover.empty?
            pending.reject! { |item| item.number == note.number }
          else
            pending << note unless pending.any? { |item| item.number == note.number }
          end

          used = actual_height
          used += gap_for(note) if index < notes.size - 1
          trailing_gap = gap_for(note) if index < notes.size - 1
          available -= used
        end

        { chunks: chunks, pending: pending }
      end

      def calculate_minima(notes)
        notes.map { |note| one_line_height(labelled_fragments(note)) }
      end

      def suffix_minimum(notes, minima, index)
        return 0 if index >= notes.size

        minima[index..].sum +
          (gap_for(notes[index]) * (notes.size - index - 1))
      end

      def chunk_with_continuation(note, height, minimum)
        fragments = labelled_fragments(note)
        marker = continuation_marker(note, :continues)
        marker_line = marker.any? ? one_line_height(marker) : 0
        body_height = height - marker_line
        raise Prawn::Errors::CannotFit if body_height < minimum

        leftover, body_actual_height = render_dry(fragments, body_height)
        [fragments, leftover, body_actual_height + marker_line]
      end

      def labelled_fragments(note)
        fragments = label_for(note)
        if note.started
          fragments += continuation_marker(note, :continued)
        end
        fragments + deep_fragments(note.fragments)
      end

      def label_for(note)
        marker = note.options[:marker] || @options[:marker] ||
          ->(number) { "#{number}. " }
        normalize_marker(marker.call(note.number))
      end

      def continuation_marker(note, state)
        marker = note.options[:continuation_marker] ||
          @options[:continuation_marker]
        return [] unless marker

        value =
          if marker.respond_to?(:call)
            marker.call(note.number, state)
          else
            marker
          end
        normalize_marker(value)
      end

      def normalize_marker(value)
        case value
        when Array
          deep_fragments(value)
        when nil
          []
        else
          [{ text: value.to_s }]
        end
      end

      def draw_current_page
        bottom = @page_bottom

        @chunks.reverse.each_with_index do |chunk, index|
          bottom += gap_for(chunk) if index.positive?
          render_chunk(chunk, bottom)
          bottom += chunk.height
        end

        return unless separator?

        @document.canvas do
          @document.stroke_horizontal_line(
            @document.margin_box.absolute_left,
            @document.margin_box.absolute_left + separator_width,
            at: bottom + separator_gap,
          )
        end
      end

      def render_chunk(chunk, bottom)
        @document.canvas do
          marker_height = one_line_height(chunk.end_marker)
          body_height = chunk.height - marker_height
          build_box(
            chunk.fragments,
            @document.margin_box.width,
            body_height,
            chunk.options,
            at: [
              @document.margin_box.absolute_left,
              bottom + body_height,
            ],
          ).render

          next if chunk.end_marker.empty?

          build_box(
            chunk.end_marker,
            @document.margin_box.width,
            marker_height,
            chunk.options,
            at: [
              @document.margin_box.absolute_left,
              bottom + chunk.height,
            ],
            align: :right,
          ).render
        end
      end

      def one_line_height(fragments)
        _leftover, height = render_dry(
          fragments, 1_000_000, single_line: true
        )
        height
      end

      def render_dry(fragments, height, single_line: false)
        box = build_box(
          fragments,
          width,
          height,
          { single_line: single_line },
        )
        [box.render(dry_run: true), box.height]
      end

      def width
        @document.margin_box.width
      end

      def build_box(fragments, box_width, height, options, extra = {})
        Prawn::Text::Formatted::Box.new(
          deep_fragments(fragments),
          {
            document: @document,
            width: box_width,
            height: height,
            overflow: :truncate,
          }.merge(box_options(options)).merge(extra)
        )
      end

      def box_options(options)
        options.slice(
          :size, :leading, :kerning, :align, :valign,
          :character_spacing, :mode, :direction, :fallback_fonts,
          :disable_wrap_by_char, :color, :style, :font,
          :single_line
        )
      end

      def gap_for(object)
        object.options.fetch(:gap, @options.fetch(:gap, DEFAULT_GAP))
      end

      def reserved_height_for(chunks)
        return 0 if chunks.empty?

        separator_height + chunks.sum(&:height) +
          chunks.first(chunks.size - 1).sum { |chunk| gap_for(chunk) }
      end

      def separator?
        @options.fetch(:separator, true)
      end

      def separator_gap
        @options.fetch(:separator_gap, DEFAULT_SEPARATOR_GAP)
      end

      def separator_height
        separator? ? separator_gap : 0
      end

      def separator_width
        case @options[:separator_width]
        when :full
          width
        when nil
          width * DEFAULT_SEPARATOR_WIDTH_RATIO
        else
          @options[:separator_width]
        end
      end

      def copy_note(note, started: note.started)
        Footnote.new(
          number: note.number,
          fragments: deep_fragments(note.fragments),
          options: note.options.dup,
          started: started,
        )
      end

      def normalize_fragments(text)
        if text.is_a?(Array)
          return tokenize_fragments(text.map { |part|
            part.is_a?(Hash) ? part : { text: part }
          })
        end

        tokenize_fragments([{ text: text.to_s }])
      end

      def deep_fragments(fragments)
        fragments.map(&:dup)
      end

      def tokenize_fragments(fragments)
        fragments.flat_map do |fragment|
          fragment = fragment.dup
          text = fragment.delete(:text).to_s
          text.scan(/\S+|\s+/).map do |token|
            fragment.merge(text: token)
          end
        end
      end
    end

    module DocumentMethods
      # Adds a numbered footnote. The block is rendered after its first chunk
      # is reserved. Use #footnote_reference inside flowing formatted text.
      #
      # @param text [String, Array<Hash>] footnote body
      # @param options [Hash] footnote and text options
      # @option options :marker [#call] footnote label renderer
      # @option options :continuation_marker [#call] split marker renderer
      # @option options :gap [Numeric] gap above the footnote
      # @yieldparam number [Integer] stable footnote number
      # @return [Integer] footnote number
      # @raise [Prawn::Errors::FootnoteCannotFit]
      def footnote(text, options = {}, &block)
        number = if block
          footnotes_manager.add_anchor(text, options)
        else
          footnotes_manager.add(text, options)
        end
        if block
          footnotes_manager.render_anchor_block_with_retry(number, block)
        end
        number
      end

      # @return [Hash] document-wide footnote options
      def footnotes_options
        @footnotes_options ||= {}
      end

      # Updates document-wide footnote options.
      # @param options [Hash] footnote options
      # @return [Hash]
      def configure_footnotes(options = {})
        footnotes_options.merge!(options)
      end

      # Builds a formatted fragment containing the footnote anchor marker.
      # @param number [Integer] footnote number
      # @param options [Hash] formatted fragment options
      # @return [Hash]
      def footnote_reference(number, options = {})
        options = options.dup
        text = options.delete(:text) { number.to_s }
        options[:styles] = Array(options[:styles]).dup.push(:superscript)
        options[:draw_text_callback] = ->(*) do
          footnotes_anchor_drawn(number)
        end
        { text: text }.merge(options)
      end

      def footnotes_manager
        @footnotes_manager ||= Manager.new(self, footnotes_options)
      end

      def footnotes_finish_page
        @footnotes_manager&.finish_page
      end

      def footnotes_anchor_drawn(number)
        @footnotes_manager&.anchor_drawn(number, page_number)
      end

      def start_new_page(options = {})
        footnotes_finish_page
        super
      end

      def render(*arguments)
        @footnotes_manager&.finish_document
        super
      end
    end

    module BoundingBoxMethods
      def move_past_bottom
        document.footnotes_finish_page
        super
      end
    end

    module ColumnBoxMethods
      def move_past_bottom
        document.footnotes_finish_page if @current_column == @columns - 1
        super
      end
    end

    Document::BoundingBox.prepend(BoundingBoxMethods)
    Document::ColumnBox.prepend(ColumnBoxMethods)
    Document.prepend(DocumentMethods)
  end

  class Document
    class BoundingBox
      def reserve_footnote_height(height, original_bottom)
        @height = @y - original_bottom - height
        @stretched_height = nil
        self
      end
    end
  end
end
