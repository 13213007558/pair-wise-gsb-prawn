# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # Chooses paragraph-wide line breaks instead of greedily filling lines.
      #
      # @private
      class OptimalLineBreak
        Line = Struct.new(
          :fragments, :width, :space_count, :adjustment, :hyphenated,
          :ratio, :first, :last
        )

        attr_reader :lines
        attr_reader :work_units

        def initialize(document, width:, kerning:, stretch:, shrink:, justify:,
                       disable_wrap_by_char: false)
          @document = document
          @arranger = Arranger.new(document, kerning: kerning)
          @tokenizer = LineWrap.new
          @width = width
          @kerning = kerning
          @stretch = stretch
          @shrink = shrink
          @justify = justify
          @disable_wrap_by_char = disable_wrap_by_char
          @work_units = 0
        end

        def layout(formatted_text)
          @lines = []
          @work_units = 0
          output = []
          paragraphs = each_paragraph(formatted_text)

          paragraphs.each_with_index do |paragraph, index|
            paragraph_lines = layout_paragraph(paragraph)
            @lines.concat(paragraph_lines)
            paragraph_lines.each_with_index do |line, line_index|
              output.concat(line.fragments)
              if line_index < paragraph_lines.length - 1
                output << paragraph[:separator_state].merge(text: "\n")
              end
            end

            next if index == paragraphs.length - 1

            output << paragraph[:separator_state].merge(text: "\n")
          end

          output
        end

        def self.layout(formatted_text, document:, width:, kerning: false,
                       stretch: nil, shrink: nil, justify: true)
          stretch ||= document.width_of(' ', kerning: kerning)
          shrink ||= stretch * 0.5

          new(
            document,
            width: width,
            kerning: kerning,
            stretch: stretch,
            shrink: shrink,
            justify: justify,
          ).layout(formatted_text)
        end

        private

        def each_paragraph(formatted_text)
          paragraphs = []
          current = []

          formatted_text.each do |hash|
            text = hash[:text].to_s
            position = 0

            text.split("\n", -1).each_with_index do |part, part_index|
              unless part.empty?
                current << source_state(hash, position, part)
                position += part.length
              end

              next unless part_index < text.count("\n")

              paragraphs << {
                atoms: current,
                separator_state: without_key(hash, :text),
              }
              current = []
              position += 1
            end
          end

          paragraphs << { atoms: current, separator_state: {} } if current.any?
          paragraphs
        end

        def source_state(hash, position, part)
          hash.merge(
            text: part,
            source_hash_id: hash.object_id,
            source_position: position,
          )
        end

        def layout_paragraph(paragraph)
          atoms = atoms_for(paragraph[:atoms])
          return [empty_line] if atoms.empty?

          force_character_breaks(atoms)
          atoms.shift if atoms.first[:glue]
          prepare_line_measurements(atoms)
          endpoints = ([0] + break_positions(atoms) + [atoms.length]).sort.uniq
          costs = {
            0 => {
              [1, false] => { score: [0, 0], back: nil },
            },
          }

          endpoints.drop(1).each do |endpoint|
            costs[endpoint] = best_paths_to(endpoint, endpoints, costs, atoms)
          end

          final_states = costs[atoms.length]
          raise Prawn::Errors::CannotFit if final_states.nil? || final_states.empty?

          state = best_state(final_states)
          choices = []
          endpoint = atoms.length

          while endpoint != 0
            entry = final_states.fetch(state)
            choice = entry.fetch(:back)
            choices << choice
            endpoint = choice.fetch(:start)
            state = [
              choice.fetch(:previous_fitness),
              choice.fetch(:previous_hyphenated),
            ]
            final_states = costs[endpoint]
            endpoint += 1 if endpoint < atoms.length && atoms[endpoint][:glue]
          end

          choices.reverse.map.with_index do |choice, index|
            line = choice.fetch(:line).dup
            finish = index == choices.length - 1
            line.fragments = fragments_for(line, atoms, finish)
            line
          end
        end

        def exhaustive_lines(atoms)
          prepare_line_measurements(atoms)
          forced = forced_positions(atoms)
          optional = break_positions(atoms) - forced
          best = nil

          (0..optional.length).each do |count|
            optional.combination(count).each do |selection|
              boundaries =
                ([0] + forced + selection + [atoms.length]).sort.uniq
              lines = []
              valid = true

              boundaries.each_cons(2) do |start, endpoint|
                line = line_between(
                  start,
                  endpoint,
                  atoms,
                  endpoint == atoms.length,
                )
                unless line
                  valid = false
                  break
                end
                lines << line
              end

              next unless valid

              fitness = 1
              hyphenated = false
              cost = 0

              lines.each_with_index do |line, index|
                line_fitness = fitness_for(line.ratio)
                cost += line_cost(
                  line,
                  line_fitness,
                  fitness,
                  hyphenated,
                  index == lines.length - 1,
                )
                fitness = line_fitness
                hyphenated = line.hyphenated
              end

              score = [cost, lines.length]
              if best.nil? || (score <=> best.first) == -1
                best = [score, lines]
              end
            end
          end

          raise Prawn::Errors::CannotFit if best.nil?

          best.last
        end

        def best_paths_to(endpoint, endpoints, costs, atoms)
          paths = {}
          finish = endpoint == atom_count(atoms)

          endpoints.take_while { |start| start < endpoint }.each do |start|
            line = line_between(start, endpoint, atoms, finish)
            next unless line

            fitness = fitness_for(line.ratio)

            costs.fetch(start, {}).each do
              |(previous_fitness, previous_hyphenated), entry|
              @work_units += 1
              cost = line_cost(
                line,
                fitness,
                previous_fitness,
                previous_hyphenated,
                finish,
              )
              score = [entry.dig(:score, 0) + cost, entry.dig(:score, 1) + 1]
              key = [fitness, line.hyphenated]
              candidate = {
                score: score,
                back: {
                  start: start,
                  previous_fitness: previous_fitness,
                  previous_hyphenated: previous_hyphenated,
                  line: line,
                },
              }

              existing_score = paths.dig(key, :score)
              if existing_score.nil? || (score <=> existing_score) == -1
                paths[key] = candidate
              end
            end
          end

          paths
        end

        def atom_count(atoms)
          @atom_counts ||= {}
          @atom_counts[atoms.object_id] ||= atoms.length
        end

        def best_state(states)
          states.min_by { |_state, entry| entry.fetch(:score) }.first
        end

        def atoms_for(parts)
          parts.flat_map do |part|
            state = without_key(part, :source_position)

            @tokenizer.tokenize(part[:text]).filter_map do |token|
              next if token.empty?

              glue = token.strip.empty?
              soft = !glue && token.end_with?(Prawn::Text::SHY)
              hard = !glue && !soft && token.end_with?('-')
              display = display_text(token, soft: soft)
              width = measure(display, state)
              break_width = soft ? measure(token, state) : width

              {
                source: state,
                source_hash_id: part[:source_hash_id],
                text: token,
                display: display,
                width: width,
                break_width: break_width,
                glue: glue,
                soft: soft,
                hard: hard,
                spaces: display.count(' '),
              }
            end
          end
        end

        def display_text(token, soft:)
          text = token.gsub(Prawn::Text::ZWSP, '')
          text = text.gsub(Prawn::Text::SHY, '') if soft
          text
        end

        def measure(text, state)
          return 0 if text.empty?

          fragment = Fragment.new(text, measurement_state(state), @document)
          width = nil
          @arranger.apply_font_settings(fragment) do
            width = @document.width_of(fragment.text, kerning: @kerning)
          end
          width
        end

        def measurement_state(state)
          without_keys(state, :text, :source_hash_id)
        end

        def force_character_breaks(atoms)
          expanded = atoms.flat_map do |atom|
            minimum_width = atom[:soft] ? atom[:break_width] : atom[:width]
            next atom if atom[:glue] || minimum_width <= @width

            if @disable_wrap_by_char
              raise Prawn::Errors::CannotFit
            end

            characters = character_atoms_for(atom)
            if characters.any? { |character| character[:width] > @width }
              raise Prawn::Errors::CannotFit
            end

            mark_forced_character_breaks(characters)
          end

          atoms.replace(expanded.compact)
          force_unbreakable_boundaries(atoms)
        end

        def character_atoms_for(atom)
          text = atom[:soft] ? atom[:text].delete(Prawn::Text::SHY) : atom[:text]

          text.each_char.map do |character|
            width = measure(character, atom[:source])
            atom.merge(
              text: character,
              display: character,
              width: width,
              break_width: width,
              soft: false,
              hard: character == '-',
              spaces: 0,
            )
          end
        end

        def mark_forced_character_breaks(characters)
          run_width = 0

          characters.each_with_index do |character, index|
            if run_width + character[:width] > @width
              characters[index - 1][:forced] = true
              run_width = character[:width]
            else
              run_width += character[:width]
            end
          end
        end

        def force_unbreakable_boundaries(atoms)
          run_start = 0
          run_width = 0

          atoms.each_with_index do |atom, index|
            if atom[:glue] || atom[:soft] || atom[:hard]
              run_start = index + 1
              run_width = 0
              next
            end

            run_width += atom[:width]
            next unless run_width > @width

            previous = atoms[index - 1]
            next unless index > run_start
            next if previous[:glue] || previous[:soft] || previous[:hard]

            previous[:forced] = true
            run_start = index
            run_width = atom[:width]
          end
        end

        def break_positions(atoms)
          atoms.each_index.filter_map do |index|
            atom = atoms[index]
            next index if atom[:glue] && index.positive?

            position = index + 1
            next position if atom[:soft] || atom[:hard] || atom[:forced]
          end
        end

        def forced_positions(atoms)
          atoms.each_index.filter_map do |index|
            index + 1 if atoms[index][:forced]
          end
        end

        def prepare_line_measurements(atoms)
          @prefix_widths = [0]
          @prefix_spaces = [0]
          @last_content_indexes = []
          last_content_index = -1

          atoms.each do |atom|
            @prefix_widths << @prefix_widths.last + atom[:width]
            @prefix_spaces << @prefix_spaces.last + atom[:spaces]
            last_content_index = @last_content_indexes.length unless atom[:glue]
            @last_content_indexes << last_content_index
          end
        end

        def line_between(start, endpoint, atoms, finish)
          first = start
          first += 1 if first < atoms.length && atoms[first][:glue]

          content_end = @last_content_indexes[endpoint - 1]
          last =
            if endpoint == atoms.length
              content_end
            else
              endpoint - 1
            end
          return empty_line if last < first

          width = @prefix_widths[last + 1] - @prefix_widths[first]
          spaces = @prefix_spaces[last + 1] - @prefix_spaces[first]

          last_atom = atoms[last]
          selected_soft = !last_atom[:glue] &&
            last_atom[:soft] &&
            last == endpoint - 1 &&
            !finish
          width += last_atom[:break_width] - last_atom[:width] if selected_soft
          hyphenated = last_atom[:hard] || selected_soft
          ratio = adjustment_ratio(width, spaces, finish)
          return nil unless valid_ratio?(ratio, finish, spaces)

          adjustment =
            if @justify && !finish && spaces.positive?
              adjustment_for(ratio)
            else
              0
            end

          Line.new(nil, width, spaces, adjustment, hyphenated, ratio, first, last)
        end

        def adjustment_ratio(width, spaces, finish)
          remaining = @width - width

          if !@justify
            remaining >= 0 ? 0 : -Float::INFINITY
          elsif remaining >= 0
            return Float::INFINITY if spaces.zero?
            return Float::INFINITY if @stretch.zero?

            remaining.to_f / (spaces * @stretch)
          else
            return -Float::INFINITY if spaces.zero? || @shrink.zero?

            remaining.to_f / (spaces * @shrink)
          end
        end

        def valid_ratio?(ratio, finish, _spaces)
          return false if ratio.infinite? && ratio.negative?
          return ratio.zero? if !@justify
          return false if finish && ratio.negative?
          return true if finish

          return true if ratio.infinite? && ratio.positive?

          ratio.finite? && ratio >= -1 && ratio <= 1
        end

        def adjustment_for(ratio)
          if ratio >= 0
            [ratio, 1].min * @stretch
          else
            [ratio, -1].max * @shrink
          end
        end

        def fitness_for(ratio)
          if ratio < -0.5
            0
          elsif ratio < 0.5
            1
          elsif ratio < 1
            2
          else
            3
          end
        end

        def line_cost(line, fitness, previous_fitness, previous_hyphenated, finish)
          badness = line.ratio.infinite? ? 10_000 : [10_000, 100 * line.ratio.abs**3].min
          demerits = (1 + badness)**2
          demerits += 1_000 if (fitness - previous_fitness).abs > 1
          demerits += 5_000 if line.hyphenated && previous_hyphenated
          demerits += final_line_penalty(line, finish)
          demerits
        end

        def final_line_penalty(line, finish)
          return 0 unless finish

          fill_ratio = (@width - line.width).to_f / @width
          return 0 unless fill_ratio.positive?

          [100, 100 * fill_ratio**3].min + (fill_ratio > 0.5 ? 50 : 0)
        end

        def fragments_for(line, atoms, finish)
          groups = []

          (line.first..line.last).each do |index|
            atom = atoms[index]
            selected_soft = atom[:soft] && index == line.last && !finish
            text = selected_soft ? atom[:text] : atom[:display]
            next if text.empty?

            source_hash_id = atom.fetch(:source_hash_id)
            group = groups.last
            if group && group[:source_hash_id] == source_hash_id
              group[:text] += text
              group[:normalized_soft_hyphen] = Prawn::Text::SHY if selected_soft
            else
              groups << {
                source_hash_id: source_hash_id,
                state: atom[:source],
                text: +text,
                normalized_soft_hyphen: selected_soft ? Prawn::Text::SHY : nil,
              }
            end
          end

          groups.map do |group|
            output_state(
              group[:state],
              group[:text],
              !group[:normalized_soft_hyphen].nil?,
            )
          end
        end

        def output_state(state, text, selected_soft)
          result = without_keys(
            state,
            :source_position,
            :source_hash_id,
          ).merge(text: text)
          if selected_soft
            result[:normalized_soft_hyphen] = Prawn::Text::SHY
          end
          result
        end

        def empty_line
          Line.new([], 0, 0, 0, false, 0)
        end

        def without_key(hash, key)
          without_keys(hash, key)
        end

        def without_keys(hash, *keys)
          hash.dup.tap { |result| keys.each { |key| result.delete(key) } }
        end
      end
    end
  end
end
