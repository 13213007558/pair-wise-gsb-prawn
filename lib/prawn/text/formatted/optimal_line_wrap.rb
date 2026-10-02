# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # Paragraph-wide line breaking.
      #
      # This planner uses dynamic programming over the legal break points in a
      # paragraph.  Formatting fragments are measured in their own font,
      # size, and style.
      #
      # @private
      class OptimalLineWrap
        Atom = Struct.new(
          :text,
          :state,
          :fragment_index,
          :kind,
          :width,
          :selected_width,
          keyword_init: true,
        )

        HYPHEN_PENALTY = 0.1
        CONSECUTIVE_HYPHEN_PENALTY = 0.5
        CHARACTER_PENALTY = 100.0
        LAST_LINE_FACTOR = 100.0
        EPSILON = 1e-9

        attr_reader :lines, :breaks, :cost, :word_spacings

        def initialize(array, options = {})
          @array = array
          @document = options.fetch(:document)
          @kerning = options.fetch(:kerning, false)
          @width = options.fetch(:width)
          @justify = options.fetch(:justify, false)
          @disable_wrap_by_char = options.fetch(:disable_wrap_by_char, false)
          @character_spacing = options.fetch(:character_spacing, 0)
          @min_word_spacing, @max_word_spacing = word_spacing_bounds(options)
          @tokenizer = LineWrap.new
          @measurement_cache = {}
        end

        def wrap
          atoms = build_atoms
          prefixes = prefix_widths(atoms)
          costs = { [0, false] => 0.0 }
          predecessors = {}
          queued = { [0, false] => true }

          queue = [[0, false]]
          until queue.empty?
            previous_state = queue.shift
            queued.delete(previous_state)
            previous_cost = costs[previous_state]
            start, previous_hyphen = previous_state

            each_break(atoms, start, previous_hyphen, prefixes) do |candidate|
              line_cost = candidate[:cost]
              word_spacing = candidate[:word_spacing]
              total_cost = previous_cost + line_cost
              state = [candidate[:next_start], candidate[:hyphen]]
              if total_cost < (costs[state] || Float::INFINITY)
                costs[state] = total_cost
                predecessors[state] = {
                  candidate: candidate,
                  previous: previous_state,
                  word_spacing: word_spacing,
                }
                unless queued.key?(state)
                  queue << state
                  queued[state] = true
                end
              end
            end
          end

          final_start = first_visible_index(atoms, 0)
          final_candidate = {
            start: final_start,
            finish: atoms.length - 1,
            next_start: atoms.length,
            kind: :final,
            hyphen: false,
            previous_hyphen: false,
          }

          best_final_state = nil
          costs.each_key do |state|
            start, previous_hyphen = state
            next unless visible_index?(atoms, start)

            candidate = final_candidate.merge(
              start: start,
              previous_hyphen: previous_hyphen,
            )
            line_cost, = line_cost(candidate, atoms, prefixes, true)
            next if line_cost.nil?

            total_cost = costs[state] + line_cost
            if best_final_state.nil? || total_cost < costs[best_final_state]
              best_final_state = state
              @cost = total_cost
            end
          end

          raise Prawn::Errors::CannotFit if best_final_state.nil?

          reconstruct(best_final_state, predecessors, atoms, final_candidate)
          @lines
        end

        private

        def word_spacing_bounds(options)
          value = options[:word_spacing] || {}
          bounds =
            if value.is_a?(Hash)
              [value[:min], value[:max]]
            elsif value.is_a?(Range)
              [value.min, value.max]
            else
              [0, Float::INFINITY]
            end

          [bounds[0] || 0, bounds[1].nil? ? Float::INFINITY : bounds[1]]
        end

        def build_atoms
          atoms = []
          @array.each_with_index do |hash, fragment_index|
            state = hash.dup
            text = state.delete(:text).to_s
            next if text.empty?

            @tokenizer.tokenize(text).each do |token|
              add_token(atoms, token, state, fragment_index)
            end
          end
          atoms
        end

        def add_token(atoms, token, state, fragment_index)
          encoding = token.encoding
          if token == Prawn::Text::SHY.encode(encoding)
            atoms << atom(
              token,
              state,
              fragment_index,
              :shy,
              '',
              0,
              measure(token, state, fragment_index),
            )
            return
          end

            zero_width_space =
              begin
                Prawn::Text::ZWSP.encode(encoding)
              rescue ::Encoding::InvalidByteSequenceError,
                     ::Encoding::UndefinedConversionError
                nil
              end

          if token.match?(/\A[\s#{zero_width_space}]+\z/)
            atoms << atom(token, state, fragment_index, :space, token)
            return
          end

          if token.end_with?(Prawn::Text::SHY.encode(encoding)) &&
              token != Prawn::Text::SHY.encode(encoding)
            base = token[0...-1]
            shy = token[-1]
            atoms << atom(base, state, fragment_index, :text, base)
            atoms << atom(
              shy,
              state,
              fragment_index,
              :shy,
              0,
              0,
              measure(shy, state, fragment_index),
            )
            return
          end

          token.scan(/(-+|[^-]+)/).each do |(part)|
            if part.start_with?('-')
              part.each_char do |char|
                atoms << atom(char, state, fragment_index, :hyphen, char)
              end
            elsif part.length > 1 &&
                measure(part, state, fragment_index) > @width &&
                !@disable_wrap_by_char
              part.each_char do |char|
                atoms << atom(char, state, fragment_index, :character, char)
              end
            else
              atoms << atom(part, state, fragment_index, :text, part)
            end
          end
        end

        def atom(
          text,
          state,
          fragment_index,
          kind,
          measured_text,
          width = nil,
          selected_width = 0
        )
          width ||=
            if kind == :character
              measure(text, state, fragment_index)
            else
              measure(measured_text, state, fragment_index)
            end

          Atom.new(
            text: text,
            state: state.merge(optimal_group_id: fragment_index),
            fragment_index: fragment_index,
            kind: kind,
            width: width,
            selected_width: selected_width,
          )
        end

        def measure(text, state, fragment_index)
          key = [fragment_index, text, state]
          @measurement_cache[key] ||= begin
            arranger = Arranger.new(@document, kerning: @kerning)
            arranger.format_array = [state.merge(text: text)]
            arranger.next_string
            measured_width = nil
            arranger.apply_font_settings do
              @document.character_spacing(@character_spacing) do
                measured_width =
                  @document.width_of(text, kerning: @kerning)
              end
            end
            measured_width
          end
        end

        def prefix_widths(atoms)
          width = 0.0
          atoms.each_with_object([0.0]) do |atom, prefixes|
            width += atom.width
            prefixes << width
          end
        end

        def each_break(atoms, start, previous_hyphen, prefixes)
          atoms.each_index do |break_index|
            next if break_index < start

            current = atoms[break_index]
            kind, finish, next_start =
              if current.kind == :space && break_index > start
                [:space, break_index - 1, break_index + 1]
              elsif %i[shy hyphen zwsp].include?(current.kind)
                next_start = skip_invisible(break_index + 1, atoms)
                next unless visible_after?(atoms, next_start)
                next if hyphen_before_space?(atoms, break_index)

                [current.kind, break_index, next_start]
              elsif character_break?(atoms, break_index, start)
                [:character, break_index - 1, break_index]
              end

            next unless kind && finish >= start &&
              visible_after?(atoms, next_start)

            candidate = {
              start: start,
              finish: finish,
              next_start: next_start,
              kind: kind,
              hyphen: %i[shy hyphen].include?(kind),
              previous_hyphen: previous_hyphen,
            }
            line_cost, word_spacing =
              line_cost(candidate, atoms, prefixes, false)
            if line_cost.nil?
              natural_width =
                prefixes[finish + 1] - prefixes[start] -
                  trailing_width(atoms, start, finish)
              if atoms[finish]&.kind == :shy
                natural_width +=
                  atoms[finish].selected_width - atoms[finish].width
              end
              if natural_width > @width + EPSILON
                if atoms[finish].kind == :character &&
                    !@disable_wrap_by_char &&
                    atoms[finish + 1]
                  next
                end
                break
              end
              next
            end
            candidate[:cost] = line_cost
            candidate[:word_spacing] = word_spacing
            yield(candidate)
          end
        end

        def character_break?(atoms, index, start)
          previous = atoms[index - 1]
          current = atoms[index]
          return false if previous.nil?
          return false unless visible_atom?(previous) && visible_atom?(current)
          return false if index <= start

          previous.kind == :character && current.kind == :character
        end

        def first_visible_index(atoms, start)
          index = start
          index += 1 while index < atoms.length && !visible_atom?(atoms[index])
          index
        end

        def skip_invisible(index, atoms)
          index += 1 while index < atoms.length &&
            %i[space zwsp].include?(atoms[index].kind)
          index
        end

        def visible_after?(atoms, index)
          index = skip_invisible(index, atoms)
          index < atoms.length
        end

        def visible_index?(atoms, index)
          index < atoms.length && visible_atom?(atoms[index])
        end

        def visible_atom?(atom)
          atom && !%i[space zwsp].include?(atom.kind)
        end

        def line_cost(candidate, atoms, prefixes, final_line)
          start = candidate[:start]
          finish = candidate[:finish]
          return nil unless visible_index?(atoms, start)
          return nil if finish < start

          natural_width =
            prefixes[finish + 1] - prefixes[start] - trailing_width(atoms, start, finish)
          if atoms[finish]&.kind == :shy
            natural_width += atoms[finish].selected_width - atoms[finish].width
          end
          if natural_width > @width + EPSILON
            allowed_character_break = candidate[:kind] == :character &&
              !@disable_wrap_by_char
            unless allowed_character_break
              return nil if !@justify || final_line ||
                space_count(atoms, start, finish).zero?
            end
          end

          slack = @width - natural_width
          spaces = space_count(atoms, start, finish)
          word_spacing = 0.0

          if @justify && !final_line && spaces.positive?
            minimum = spaces * @min_word_spacing
            maximum = spaces * @max_word_spacing
            return nil if slack < minimum - EPSILON

            adjustment = [slack, minimum].max
            adjustment = [adjustment, maximum].min
            word_spacing = adjustment / spaces
            slack = @width - (natural_width + adjustment)
          end

          return nil if slack.negative? && slack.abs > EPSILON

          badness = (slack.abs / @width.to_f)**2
          badness *= LAST_LINE_FACTOR if final_line
          badness += HYPHEN_PENALTY if candidate[:hyphen]
          if candidate[:hyphen] && candidate[:previous_hyphen]
            badness += CONSECUTIVE_HYPHEN_PENALTY
          end
          badness += CHARACTER_PENALTY if candidate[:kind] == :character

          [badness, word_spacing]
        end

        def hyphen_before_space?(atoms, index)
          next_index = index + 1
          next_index += 1 while next_index < atoms.length &&
            atoms[next_index].kind == :shy
          next_index < atoms.length && atoms[next_index].kind == :space
        end

        def trailing_width(atoms, start, finish)
          index = finish
          index -= 1 while index >= start && !visible_atom?(atoms[index])
          atoms[(index + 1)..finish].to_a.sum(0.0, &:width)
        end

        def space_count(atoms, start, finish)
          atoms[start..finish].to_a.sum(0) do |atom|
            next 0 unless atom.kind == :space

            atom.text.count(' ')
          end
        end

        def reconstruct(final_state, predecessors, atoms, final_candidate)
          candidates = []
          word_spacings = []
          state = final_state

          while predecessors[state]
            record = predecessors[state]
            candidates.unshift(record[:candidate])
            word_spacings.unshift(record[:word_spacing])
            state = record[:previous]
          end

          final_start, = final_state
          final = final_candidate.merge(start: final_start)
          candidates << final
          word_spacings << 0.0

          @breaks = candidates.map { |candidate| [candidate[:start], candidate[:finish]] }
          @word_spacings = word_spacings
          @lines = candidates.map.with_index do |candidate, index|
            materialize(atoms, candidate, word_spacings[index])
          end
        end

        def materialize(atoms, candidate, word_spacing)
          line = []
          pieces = []
          atoms[candidate[:start]..candidate[:finish]].to_a
            .each_with_index do |atom, offset|
            next if atom.kind == :zwsp

            selected_shy = atom.kind == :shy &&
              candidate[:start] + offset == candidate[:finish]
            next if atom.kind == :shy && !selected_shy

            pieces << [atom, selected_shy]
          end

          pieces.each do |atom, selected_shy|
            state = atom.state.dup
            state[:display_soft_hyphen] = true if selected_shy
            if selected_shy && line.last
              line.last[:text] += atom.text
              line.last[:display_soft_hyphen] = true
            elsif line.last && !selected_shy &&
                !line.last[:display_soft_hyphen] &&
                line.last[:optimal_group_id] == state[:optimal_group_id]
              line.last[:text] += atom.text
            else
              line << state.merge(text: atom.text)
            end
          end

          line.each do |hash|
            hash.delete(:optimal_group_id)
            if hash[:display_soft_hyphen] == true
              hash[:normalized_soft_hyphen] =
                Prawn::Text::SHY.encode(hash[:text].encoding)
            else
              hash.delete(:display_soft_hyphen)
              hash.delete(:normalized_soft_hyphen)
            end
          end

          line << {
            text: "\n",
            optimal_line_break: true,
            optimal_word_spacing: word_spacing,
          } if candidate[:kind] != :final

          line
        end
      end
    end
  end
end
