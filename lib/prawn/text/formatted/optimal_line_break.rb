# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # Chooses line breaks for a whole paragraph using shortest-path dynamic
      # programming.
      #
      # @private
      class OptimalLineBreak
        FORCED_BREAK_PENALTY = 1_000_000
        DEFAULT_HYPHEN_PENALTY = 10
        DEFAULT_CONSECUTIVE_HYPHEN_PENALTY = 100

        LinePlan = Struct.new(
          :fragments,
          :natural_width,
          :space_count,
          :hyphenated,
          :forced,
          :paragraph_finished,
          keyword_init: true,
        )

        Paragraph = Struct.new(:lines, :cost, keyword_init: true)

        Node = Struct.new(
          :index,
          :end_type,
          :terminal,
          keyword_init: true,
        )

        State = Struct.new(
          :cost,
          :node,
          :line,
          :previous,
          :previous_hyphen,
          keyword_init: true,
        )

        Atom = Struct.new(
          :text,
          :state,
          :width,
          :space,
          :whitespace,
          :soft_hyphen,
          :hard_hyphen,
          :forced,
          :source_index,
          keyword_init: true,
        )

        def initialize(document, arranger, options = {})
          @document = document
          @arranger = arranger
          @kerning = options[:kerning]
          @width = options[:width]
          @justify = options[:justify]
          @disable_wrap_by_char = options[:disable_wrap_by_char]
          @hyphen_penalty = penalty(
            :hyphen_penalty,
            DEFAULT_HYPHEN_PENALTY,
            options,
          )
          @consecutive_hyphen_penalty = penalty(
            :consecutive_hyphen_penalty,
            DEFAULT_CONSECUTIVE_HYPHEN_PENALTY,
            options,
          )
          @tokenizer = LineWrap.new
        end

        def paragraph
          atoms, explicit_newline = build_atoms
          lines =
            if atoms.empty?
              [blank_line_plan] if explicit_newline
            else
              plan(atoms, explicit_newline)
            end
          raise Prawn::Errors::CannotFit if lines.nil?

          cost = total_cost(lines)
          Paragraph.new(lines: lines, cost: cost)
        end

        private

        def build_atoms
          atoms = []
          saw_text = false
          explicit_newline = false

          source_index = -1
          while (text = @arranger.next_string)
            if text == "\n"
              explicit_newline = true
              break
            end

            source_index += 1
            saw_text = true
            @tokenizer.tokenize(text).each do |token|
              build_token_atoms(
                token,
                @arranger.current_format_state,
                atoms,
                source_index,
              )
            end
          end

          [atoms, explicit_newline] if saw_text || explicit_newline
        end

        def build_token_atoms(token, state, atoms, source_index)
          encoding = token.encoding
          shy = soft_hyphen(encoding)

          if whitespace?(token)
            token.each_char do |character|
              atoms << whitespace_atom(character, state, source_index)
            end
          elsif token == shy
            atoms << soft_hyphen_atom(token, state, source_index)
          elsif shy && token.end_with?(shy)
            word = token[0...-1]
            split_oversized_word(
              word,
              state,
              atoms,
              source_index,
            ) unless word.empty?
            atoms << soft_hyphen_atom(
              token[-1],
              state,
              source_index,
            )
          else
            hard_break = token.end_with?('-') && token != '-'
            if hard_break && measure(token, state) > @width
              split_oversized_word(
                token,
                state,
                atoms,
                source_index,
                hard_break: true,
              )
            else
              split_oversized_word(
                hard_break ? token[0...-1] : token,
                state,
                atoms,
                source_index,
              )
              if hard_break
                atoms << hard_hyphen_atom('-', state, source_index)
              end
            end
          end
        end

        def split_oversized_word(
          word, state, atoms, source_index, hard_break: false
        )
          width = measure(word, state)
          if width <= @width
            atoms << word_atom(
              word,
              state,
              width,
              forced: false,
              hard_hyphen: hard_break && word.end_with?('-'),
              source_index: source_index,
            )
            return
          end

          raise Prawn::Errors::CannotFit if @disable_wrap_by_char

          prefix = +''
          prefix_width = 0
          word.each_char do |character|
            character_width = measure(character, state)
            if !prefix.empty? && prefix_width + character_width > @width
              atoms << word_atom(
                prefix,
                state,
                prefix_width,
                forced: true,
                source_index: source_index,
              )
              prefix = +''
              prefix_width = 0
            end
            prefix << character
            prefix_width += character_width
          end

          unless prefix.empty?
            atoms << word_atom(
              prefix,
              state,
              prefix_width,
              forced: true,
              hard_hyphen: hard_break && prefix.end_with?('-'),
              source_index: source_index,
            )
          end
        end

        def whitespace_atom(text, state, source_index)
          width = text == Prawn::Text::ZWSP ? 0 : measure(text, state)
          atom(
            text: text,
            state: state,
            width: width,
            whitespace: true,
            space: text == ' ',
            source_index: source_index,
          )
        end

        def soft_hyphen_atom(text, state, source_index)
          atom(
            text: text,
            state: state,
            width: measure(text, state),
            soft_hyphen: true,
            source_index: source_index,
          )
        end

        def hard_hyphen_atom(text, state, source_index)
          atom(
            text: text,
            state: state,
            width: measure(text, state),
            hard_hyphen: true,
            source_index: source_index,
          )
        end

        def word_atom(
          text,
          state,
          width,
          forced:,
          hard_hyphen: false,
          source_index:
        )
          atom(
            text: text,
            state: state,
            width: width,
            forced: forced,
            hard_hyphen: hard_hyphen,
            source_index: source_index,
          )
        end

        def atom(**attributes)
          defaults = {
            space: false,
            whitespace: false,
            soft_hyphen: false,
            hard_hyphen: false,
            forced: false,
          }
          Atom.new(**defaults.merge(attributes))
        end

        def measure(text, state)
          return 0 if text == Prawn::Text::ZWSP

          @arranger.measurement_font_settings(state) do
            @document.width_of(text, kerning: @kerning)
          end
        end

        def plan(atoms, explicit_newline)
          nodes = build_nodes(atoms)
          states = {
            nodes.first => State.new(
              cost: 0,
              node: nodes.first,
              previous_hyphen: false,
            ),
          }

          nodes.each do |start_node|
            start_state = states[start_node]
            next if start_state.nil?
            next if start_node.terminal

            nodes.each do |end_node|
              next if end_node.index <= start_node.index

              start = line_start(start_node.index, atoms)
              next if start >= end_node.index

              line = build_line(
                atoms,
                start,
                end_node.index,
                end_node.terminal,
              )
              next unless fits?(line)

              cost = transition_cost(
                line,
                end_node.end_type,
                start_state.previous_hyphen,
              ) + start_state.cost
              current = states[end_node]
              if current.nil? || cost < current.cost - Prawn::FLOAT_PRECISION
                states[end_node] = State.new(
                  cost: cost,
                  node: end_node,
                  line: line,
                  previous: start_state,
                  previous_hyphen:
                    end_node.end_type == :soft || end_node.end_type == :hard,
                )
              end
            end
          end

          terminal = nodes.find(&:terminal)
          terminal_state = states[terminal]
          raise Prawn::Errors::CannotFit if terminal_state.nil?

          lines = []
          state = terminal_state
          while state.line
            lines.unshift(state.line)
            state = state.previous
          end
          lines << blank_line_plan if explicit_newline
          lines
        end

        def build_nodes(atoms)
          nodes = [Node.new(index: 0, end_type: nil, terminal: false)]

          atoms.each_with_index do |item, index|
            boundary = index + 1
            end_type =
              if item.soft_hyphen
                :soft
              elsif item.hard_hyphen
                :hard
              elsif item.forced
                :forced
              elsif item.whitespace
                :space
              end
            nodes << Node.new(
              index: boundary,
              end_type: end_type,
              terminal: false,
            ) if end_type
          end

          last_break = nodes.reverse.find { |node| node.index == atoms.length }
          if last_break
            last_break.terminal = true
          else
            nodes << Node.new(
              index: atoms.length,
              end_type: nil,
              terminal: true,
            )
          end
          nodes
        end

        def line_start(index, atoms)
          index += 1 while index < atoms.length && atoms[index].whitespace
          index
        end

        def build_line(atoms, start, boundary, terminal)
          line_atoms = atoms[start...boundary]
          visible_end = line_atoms.length
          visible_end -= 1 while visible_end.positive? &&
            line_atoms[visible_end - 1].whitespace
          visible_atoms = line_atoms[0...visible_end]
          last_atom = visible_atoms.last
          selected_soft_hyphen = !terminal && last_atom&.soft_hyphen

          LinePlan.new(
            fragments: build_fragments(
              visible_atoms,
              selected_soft_hyphen: selected_soft_hyphen,
            ),
            natural_width: visible_atoms.sum { |item|
              if item.soft_hyphen &&
                  !(selected_soft_hyphen && item == last_atom)
                0
              else
                item.width
              end
            },
            space_count: visible_atoms.count { |item| item[:space] },
            hyphenated: last_atom &&
              (last_atom.soft_hyphen || last_atom.hard_hyphen),
            forced: last_atom&.forced || false,
            paragraph_finished: terminal,
          )
        end

        def blank_line_plan
          LinePlan.new(
            fragments: [{ text: "\n" }],
            natural_width: 0,
            space_count: 0,
            hyphenated: false,
            forced: false,
            paragraph_finished: true,
          )
        end

        def build_fragments(atoms, selected_soft_hyphen: false)
          last_atom = atoms.last
          atoms
            .slice_when { |left, right|
              left.state != right.state || left.source_index != right.source_index
            }
            .map do |group|
              state = group.first.state.dup
              has_soft_hyphen = group.any?(&:soft_hyphen)
              text = group.map { |item|
                if selected_soft_hyphen &&
                    item.soft_hyphen &&
                    item.equal?(last_atom)
                  '-'
                elsif item.soft_hyphen
                  ''
                else
                  item.text
                end
              }.join
              state[:normalized_soft_hyphen] = soft_hyphen if has_soft_hyphen
              state.merge(text: text)
            end
        end

        def fits?(line)
          line.natural_width <= @width + Prawn::FLOAT_PRECISION
        end

        def transition_cost(line, end_type, start_end_type)
          cost = line_cost(line)
          if !line.paragraph_finished &&
              (end_type == :soft || end_type == :hard)
            cost += @hyphen_penalty
            if start_end_type
              cost += @consecutive_hyphen_penalty
            end
          end
          unless line.paragraph_finished
            cost += FORCED_BREAK_PENALTY if end_type == :forced
          end
          cost
        end

        def total_cost(lines)
          lines.each_with_index.sum do |line, index|
            cost = badness(line, index == lines.length - 1)
            if line.hyphenated && !line.paragraph_finished
              cost += @hyphen_penalty
            end
            if line.hyphenated && index.positive? && lines[index - 1].hyphenated
              cost += @consecutive_hyphen_penalty
            end
            unless line.paragraph_finished
              cost += FORCED_BREAK_PENALTY if line.forced
            end
            cost
          end
        end

        def line_cost(line)
          badness(line, line.paragraph_finished)
        end

        def badness(line, last_line)
          return 0 if last_line

          slack = @width - line.natural_width
          if @justify && line.space_count.positive?
            (slack.to_f / line.space_count) ** 2
          else
            slack.to_f ** 2
          end
        end

        def whitespace?(token)
          token.each_char.all? do |character|
            character =~ /\A\s\z/ || character == Prawn::Text::ZWSP
          end
        end

        def soft_hyphen(encoding = ::Encoding::UTF_8)
          Prawn::Text::SHY.encode(encoding)
        rescue ::Encoding::InvalidByteSequenceError,
               ::Encoding::UndefinedConversionError
          nil
        end

        def penalty(name, default, options)
          options.key?(name) && !options[name].nil? ? options[name] : default
        end
      end
    end
  end
end
