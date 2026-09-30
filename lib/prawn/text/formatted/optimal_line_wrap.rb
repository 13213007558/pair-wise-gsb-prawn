# frozen_string_literal: true

require_relative '../optimal_line_break'
require_relative 'line_wrap'

module Prawn
  module Text
    module Formatted
      # Implements paragraph-wide line wrapping of formatted text.
      #
      # @private
      class OptimalLineWrap < LineWrap
        attr_reader :width, :space_count, :adjustment, :line_adjustments,
                    :line_plans

        def initialize(stretch: nil, shrink: nil)
          super()
          @stretch = stretch
          @shrink = shrink
          @line_adjustments = []
          @line_plans = []
        end

        def wrap_line(options)
          reset_adjustments = @plans.nil? || @line_index.to_i.zero?
          initialize_line(options)
          @line_adjustments = [] if reset_adjustments
          @line_plans = [] if reset_adjustments
          prepare_plan unless @plans
          load_next_plan
          @line_adjustments << @adjustment
          line
        end

        def paragraph_finished?
          @paragraph_finished || @arranger.finished?
        end

        private

        def prepare_plan
          entries = build_entries
          items = build_items(entries)
          justified = options_justify?
          result = Prawn::Text::OptimalLineBreak.new(
            items,
            width: @width,
            justified: justified,
          ).call
          @plans = result.lines.map do |line|
            arrangement = build_line_arrangement(items, line)
            {
              fragments: arrangement[:fragments],
              width: line.width,
              space_count: count_spaces(arrangement[:visible_fragments]),
              adjustment: line.adjustment,
              paragraph_finished: line.paragraph_end,
              consumed_position: arrangement[:consumed_position],
              text: line_text(
                line,
                items,
                arrangement[:visible_fragments],
              ),
            }
          end
          @line_index = 0
          @source_hashes = @arranger.unconsumed.map(&:dup)
        end

        def options_justify?
          @justify == :justify
        end

        def initialize_line(options)
          super
          @justify = options[:justify] || :left
          @plans = nil if @plans && @line_index >= @plans.length
        end

        def load_next_plan
          plan = @plans[@line_index]
          @line_index += 1

          if plan.nil?
            @width = 0
            @space_count = 0
            @adjustment = 0
            return
          end

          fragments = plan[:fragments]
          remaining = remaining_entries(plan[:consumed_position])
          set_arranger_for_line(fragments, remaining)

          @width = plan[:width]
          @space_count = plan[:space_count]
          @adjustment = plan[:adjustment]
          @paragraph_finished = plan[:paragraph_finished]
          @line_plans << {
            text: plan[:text],
            adjustment: @adjustment,
          }
        end

        def set_arranger_for_line(fragments, remaining)
          @arranger.consumed = fragments
          @arranger.unconsumed = remaining
          @arranger.finalize_line
        end

        def line
          @arranger.line
        end

        def build_entries
          @arranger.unconsumed.each_with_index.flat_map do |hash, source_index|
            split_text_on_newlines(hash[:text]).map do |text, start_position|
              entry = hash.merge(text: text, source_index: source_index)
              entry[:original_start] = start_position
              entry
            end
          end
        end

        def split_text_on_newlines(text)
          entries = []
          position = 0
          text.split(/(\n)/).reject(&:empty?).each do |part|
            entries << [part, position]
            position += part.length
          end
          entries
        end

        def build_items(entries)
          items = []
          entries.each do |entry|
            text = entry[:text]
            if text == "\n"
              text.each_char.with_index do |_character, index|
                items << forced_break_item(entry, index, index + 1)
              end
            else
              build_items_for_entry(entry, items)
            end
          end
          items
        end

        def build_items_for_entry(entry, items)
          text = entry[:text]
          text.scan(scan_pattern(text.encoding)) do
            match = Regexp.last_match
            token = match[0]
            start_position = match.begin(0)
            end_position = match.end(0)
            absolute_start = entry[:original_start].to_i + start_position
            absolute_end = entry[:original_start].to_i + end_position
            if whitespace_token?(token)
              add_glue_item(
                token, entry, absolute_start, absolute_end, items,
              )
            else
              add_text_token(
                token, entry, absolute_start, absolute_end, items,
              )
            end
          end
        end

        def add_glue_item(token, entry, start_position, end_position, items)
          spaces = token.count(' ')
          width = measure(token, entry)
          stretch_capacity = 0.0
          shrink_capacity = 0.0
          if spaces.positive?
            space_width = measure(' ', entry)
            stretch_capacity = @stretch || space_width
            shrink_capacity = @shrink || space_width * 0.5
          end

          items << OptimalLineBreak::Item.new(
            kind: :glue,
            text: token,
            width: width,
            stretch: stretch_capacity,
            shrink: shrink_capacity,
            spaces: spaces,
            metadata: metadata(entry, start_position, end_position),
          )
        end

        def add_text_token(token, entry, start_position, end_position, items)
          shy = soft_hyphen(token.encoding)
          if token.end_with?(shy)
            prefix = token[0...-1]
            unless prefix.empty?
              add_box(
                prefix, entry, start_position, end_position - 1, items,
              )
            end
            items << OptimalLineBreak::Item.new(
              kind: :penalty,
              text: shy,
              width: measure(shy, entry),
              stretch: 0,
              shrink: 0,
              spaces: 0,
              penalty: 0,
              forced: false,
              paragraph_end: false,
              hyphen: true,
              metadata:
                metadata(entry, end_position - 1, end_position),
            )
          elsif token.end_with?('-') && token != '-'
            add_box(
              token,
              entry,
              start_position,
              end_position,
              items,
              hyphen: true,
            )
          else
            add_box(
              token,
              entry,
              start_position,
              end_position,
              items,
            )
          end
        end

        def add_box(text, entry, start_position, end_position, items, hyphen: false)
          if measure(text, entry) > @width
            split_box(
              text, entry, start_position, end_position, items, hyphen: hyphen,
            )
          else
            items << box_item(
              text, entry, start_position, end_position,
              hyphen: hyphen, break_after: hyphen,
            )
          end
        end

        def split_box(text, entry, start_position, _end_position, items, hyphen:)
          raise Prawn::Errors::CannotFit if @disable_wrap_by_char

          chunks = split_text_to_width(text, entry, start_position)
          chunks.each_with_index do |(chunk, chunk_start, chunk_end), index|
            last = index == chunks.length - 1
            if last
              items << box_item(
                chunk, entry, chunk_start, chunk_end,
                hyphen: hyphen, break_after: hyphen,
              )
            else
              items << box_item(
                chunk, entry, chunk_start, chunk_end,
                hyphen: false, break_after: true, forced: true,
              )
            end
          end
        end

        def split_text_to_width(text, entry, start_position)
          chunks = []
          current = +''
          current_start = start_position
          current_end = start_position
          text.each_char do |char|
            raise Prawn::Errors::CannotFit if measure(char, entry) > @width

            candidate = current + char
            if current.empty? || measure(candidate, entry) <= @width
              current = candidate
              current_end += 1
            else
              chunks << [current, current_start, current_end]
              current = +char
              current_start = current_end
              current_end += 1
            end
          end
          chunks << [current, current_start, current_end] unless current.empty?
          chunks
        end

        def box_item(
          text, entry, start_position, end_position,
          hyphen:, break_after:, forced: false
        )
          OptimalLineBreak::Item.new(
            kind: :box,
            text: text,
            width: measure(text, entry),
            stretch: 0,
            shrink: 0,
            spaces: 0,
            penalty: 0,
            forced: forced,
            paragraph_end: false,
            hyphen: hyphen,
            break_after: break_after,
            metadata: metadata(entry, start_position, end_position),
          )
        end

        def forced_break_item(entry, start_position, end_position)
          OptimalLineBreak::Item.new(
            kind: :break,
            text: "\n",
            width: 0,
            stretch: 0,
            shrink: 0,
            spaces: 0,
            penalty: 0,
            forced: true,
            paragraph_end: true,
            hyphen: false,
            metadata: metadata(entry, start_position, end_position),
          )
        end

        def whitespace_token?(token)
          token.match?(/\A[#{break_chars(token.encoding)}]+\z/)
        end

        def measure(text, entry)
          zwsp = zero_width_space(text.encoding)
          if zwsp && text.include?(zwsp)
            text = text.delete(zwsp)
          end
          return 0 if text.empty?

          format_state = entry.dup
          format_state.delete(:text)
          format_state.delete(:source_index)
          format_state.delete(:original_start)
          @arranger.measure_text(text, format_state)
        end

        def metadata(entry, start_position = nil, end_position = nil)
          format_state = entry.dup
          format_state.delete(:text)
          format_state.delete(:source_index)
          {
            format_state: format_state,
            source_index: entry[:source_index],
            start: start_position,
            stop: end_position,
          }
        end

        def build_line_arrangement(items, line)
          line_items = items[line.start_index..line.end_index] || []
          visible_fragments = build_visible_fragments(line_items)
          source_items = source_items_for_line(items, line)
          source_text_items = source_items.reject(&:marker?)
          source_text_items.shift if source_text_items.first&.glue?
          source_fragments = build_fragments(source_text_items)
          consumed_position = consumed_position(items, line)

          {
            fragments: source_fragments,
            visible_fragments: visible_fragments,
            consumed_position: consumed_position,
          }
        end

        def source_items_for_line(items, line)
          if line.breakpoint_index < items.length &&
              items[line.breakpoint_index]&.marker?
            items[line.start_index..line.breakpoint_index]
          elsif line.breakpoint_index < items.length &&
              items[line.breakpoint_index]&.glue?
            trailing_glue = items[line.breakpoint_index]
            preserved_glue = preserve_trailing_glue(trailing_glue)
            items[line.start_index...line.breakpoint_index] + [preserved_glue]
          else
            items[line.start_index..line.end_index] || []
          end
        end

        def consumed_position(items, line)
          if line.breakpoint_index < items.length
            item = items[line.breakpoint_index]
            if item.marker?
              return {
                source_index: item.metadata[:source_index],
                stop: item.metadata[:stop],
              }
            end
            return {
              source_index: item.metadata[:source_index],
              stop: item.metadata[:stop],
            }
          end

          last_item = items[line.end_index]
          {
            source_index: last_item.metadata[:source_index],
            stop: last_item.metadata[:stop],
          }
        end

        def remaining_entries(position)
          @source_hashes.each_with_index.flat_map do |hash, index|
            if index > position[:source_index]
              [hash.dup]
            elsif index == position[:source_index]
              text = hash[:text][position[:stop]..]
              text.nil? || text.empty? ? [] : [hash.merge(text: text)]
            else
              []
            end
          end
        end

        def build_visible_fragments(items)
          trimmed = items.reject(&:marker?)
          trimmed.shift if trimmed.first&.glue?
          trimmed.pop if trimmed.last&.glue?
          build_fragments(trimmed)
        end

        def line_text(line, items, fragments)
          return '' if line_marker?(line, items) && fragments.empty?

          text = fragments.map { |fragment| fragment[:text] }.join
          if line_marker?(line, items)
            text = text.delete_suffix("\n")
          end
          text
        end

        def line_marker?(line, items)
          line.breakpoint_index < items.length &&
            items[line.breakpoint_index]&.marker?
        end

        def build_fragments(items)
          fragments = []
          items.each do |item|
            append_item_to_fragments(item, fragments)
          end
          fragments.each { |fragment| fragment.delete(:_source_index) }
          fragments
        end

        def preserve_trailing_glue(item)
          format_state = item.metadata[:format_state].merge(
            exclude_trailing_white_space: false,
            optimal_trailing_glue: true,
          )
          item.dup.tap do |duplicate|
            duplicate.metadata = item.metadata.merge(
              format_state: format_state,
            )
          end
        end

        def append_item_to_fragments(item, fragments)
          state = item.metadata[:format_state].dup
          text = item.text
          state[:normalized_soft_hyphen] = soft_hyphen(text.encoding) if item.penalty?
          state[:_source_index] = item.metadata[:source_index]

          if mergeable_item?(item, fragments.last)
            fragments.last[:text] += text
          else
            fragments << state.merge(text: text)
          end
        end

        def mergeable_item?(item, previous)
          return false if previous.nil? || item.glue? || item.marker?

          return false unless previous[:_source_index] == item.metadata[:source_index]

          item.metadata[:format_state].all? do |key, value|
            previous[key] == value
          end
        end

        def count_spaces(fragments)
          fragments.sum { |fragment| fragment[:text].count(' ') }
        end
      end
    end
  end
end
