# frozen_string_literal: true

require_relative 'bidi_tables'

module Prawn
  module Text
    # The Unicode Bidirectional Algorithm (UAX #9).
    #
    # This module resolves the characters of a single paragraph of text to
    # their embedding levels and computes the visual (display) order of the
    # logical characters. It handles explicit embeddings and overrides
    # (LRE, RLE, LRO, RLO, PDF), directional isolates (LRI, RLI, FSI, PDI),
    # paired brackets, and automatic paragraph direction detection from the
    # first strong character.
    #
    # Character data is pinned to a fixed Unicode version
    # ({Bidi::UNICODE_VERSION}).
    #
    # Note that this module only implements reordering. It does not perform
    # Arabic shaping or mirrored-glyph substitution.
    module Bidi
      # Unicode version of the character data used by this implementation.
      UNICODE_VERSION = '13.0.0'

      # Maximum explicit embedding level allowed by UAX #9.
      MAX_DEPTH = 125

      # Bidi classes removed from the sequence after the explicit phase
      # (UAX #9 rule X9).
      REMOVED_CLASSES = %i[LRE RLE LRO RLO PDF BN].freeze

      # Isolate formatting characters (initiators and terminator).
      ISOLATE_FORMATTERS = %i[LRI RLI FSI PDI].freeze

      # Isolate initiators.
      ISOLATE_INITIATORS = %i[LRI RLI FSI].freeze

      # Strong bidi classes.
      STRONG_CLASSES = %i[L R AL].freeze

      class << self
        # Resolve the embedding levels of a single paragraph of text.
        #
        # @param string [String] a single paragraph (must not contain
        #   paragraph separators)
        # @param base_direction [:ltr, :rtl, nil]
        #   Paragraph direction. When `nil`, the direction is determined
        #   from the first strong character (UAX #9 rules P2--P3),
        #   defaulting to left-to-right.
        # @return [Array(Array<Integer>, Integer)]
        #   the resolved level of each character and the paragraph level
        def resolve_levels(string, base_direction: nil)
          codepoints = string.codepoints
          types = codepoints.map { |cp| Bidi.bidi_class(cp) }
          paragraph_level = resolve_paragraph_level(types, base_direction)

          levels, resolved_types = resolve_explicit(types, paragraph_level)
          kept, matching_pdi = sequence_structure(resolved_types)
          sequences = isolating_run_sequences(
            resolved_types, levels, kept, matching_pdi,
          )
          boundary = (0...types.length).reject { |i| removed?(types[i]) }

          resolve_weak(
            resolved_types, levels, sequences, paragraph_level, boundary,
          )
          resolve_brackets(
            resolved_types, levels, sequences, codepoints, paragraph_level,
            boundary,
          )
          resolve_neutral(
            resolved_types, levels, sequences, paragraph_level, boundary,
          )
          resolve_implicit(resolved_types, levels)
          reset_line_ends(types, levels, paragraph_level)
          assign_removed_levels(types, levels, paragraph_level)

          [levels, paragraph_level]
        end

        # Visual order of the characters of a paragraph.
        #
        # @param string [String]
        # @param base_direction [:ltr, :rtl, nil]
        # @return [Array<Integer>]
        #   logical character indices in visual (left-to-right display)
        #   order
        def visual_order(string, base_direction: nil)
          levels, paragraph_level = resolve_levels(
            string,
            base_direction: base_direction,
          )
          reorder_indices(levels, paragraph_level)
        end

        # Visual runs of a paragraph.
        #
        # Each run is a maximal sequence of characters that share one
        # embedding level and are contiguous in the logical text. Runs are
        # returned in visual (display) order.
        #
        # @param string [String]
        # @param base_direction [:ltr, :rtl, nil]
        # @return [Array<Hash>] runs with keys :level, :start and :length
        def visual_runs(string, base_direction: nil)
          levels, paragraph_level = resolve_levels(
            string,
            base_direction: base_direction,
          )
          order = reorder_indices(levels, paragraph_level)

          runs = []
          order.each do |index|
            last = runs.last
            if last &&
                last[:level] == levels[index] &&
                (index == last[:start] + last[:length] ||
                  index == last[:start] - 1)
              last[:start] = index if index < last[:start]
              last[:length] += 1
            else
              runs << { level: levels[index], start: index, length: 1 }
            end
          end
          runs
        end

        # Reorder logical indices into visual order (UAX #9 rule L2).
        #
        # @param levels [Array<Integer>]
        # @param paragraph_level [Integer]
        # @return [Array<Integer>]
        def reorder_indices(levels, paragraph_level)
          order = (0...levels.length).to_a
          lowest_odd = levels.select(&:odd?).min
          return order if lowest_odd.nil?

          highest = (levels + [paragraph_level]).max

          highest.downto(lowest_odd) do |level|
            index = 0
            while index < order.length
              if levels[order[index]] >= level
                stop = index
                stop += 1 while stop < order.length &&
                  levels[order[stop]] >= level
                order[index...stop] = order[index...stop].reverse
                index = stop
              else
                index += 1
              end
            end
          end
          order
        end

        private

        # UAX #9 rules P2--P3: determine the paragraph embedding level
        # from the first strong character, skipping over the content of
        # isolates.
        def resolve_paragraph_level(types, base_direction)
          case base_direction
          when :ltr then return 0
          when :rtl then return 1
          end

          depth = 0
          types.each do |type|
            case type
            when :LRI, :RLI, :FSI
              depth += 1
            when :PDI
              depth -= 1 if depth.positive?
            when :L
              return 0 if depth.zero?
            when :R, :AL
              return 1 if depth.zero?
            end
          end
          0
        end

        # First strong type inside the isolate starting at `index`,
        # skipping nested isolates (used for FSI resolution).
        def first_strong_inside(types, index)
          depth = 0
          ((index + 1)...types.length).each do |i|
            case types[i]
            when :LRI, :RLI, :FSI
              depth += 1
            when :PDI
              return nil if depth.zero?

              depth -= 1
            when :L
              return :L if depth.zero?
            when :R, :AL
              return :R if depth.zero?
            end
          end
          nil
        end

        def least_greater_odd(level)
          level.even? ? level + 1 : level + 2
        end

        def least_greater_even(level)
          level.even? ? level + 2 : level + 1
        end

        # UAX #9 rules X1--X9: explicit embeddings, overrides and
        # isolates.
        #
        # @return [Array(Array<Integer>, Array<Symbol>)]
        #   levels and bidi types with directional overrides applied
        def resolve_explicit(types, paragraph_level)
          levels = Array.new(types.length)
          resolved = types.dup

          stack = [{ level: paragraph_level, override: nil, isolate: false }]
          overflow_isolate_count = 0
          overflow_embedding_count = 0
          valid_isolate_count = 0

          types.each_with_index do |type, index|
            current = stack.last

            case type
            when :RLE, :LRE, :RLO, :LRO
              levels[index] = current[:level]
              new_level =
                if %i[RLE RLO].include?(type)
                  least_greater_odd(current[:level])
                else
                  least_greater_even(current[:level])
                end
              override =
                case type
                when :RLO then :R
                when :LRO then :L
                end
              if new_level <= MAX_DEPTH &&
                  overflow_isolate_count.zero? &&
                  overflow_embedding_count.zero?
                stack.push(
                  level: new_level,
                  override: override,
                  isolate: false,
                )
              elsif overflow_isolate_count.zero?
                overflow_embedding_count += 1
              end
            when :RLI, :LRI, :FSI
              levels[index] = current[:level]
              direction =
                case type
                when :RLI then :R
                when :LRI then :L
                else first_strong_inside(types, index) || :L
                end
              new_level =
                if direction == :R
                  least_greater_odd(current[:level])
                else
                  least_greater_even(current[:level])
                end
              if new_level <= MAX_DEPTH &&
                  overflow_isolate_count.zero? &&
                  overflow_embedding_count.zero?
                valid_isolate_count += 1
                stack.push(level: new_level, override: nil, isolate: true)
              else
                overflow_isolate_count += 1
              end
            when :PDI
              if valid_isolate_count.positive?
                overflow_isolate_count = 0
                overflow_embedding_count = 0
                stack.pop until stack.last[:isolate]
                stack.pop
                valid_isolate_count -= 1
                levels[index] = stack.last[:level]
              else
                levels[index] = current[:level]
              end
            when :PDF
              levels[index] = current[:level]
              if overflow_isolate_count.zero?
                if overflow_embedding_count.positive?
                  overflow_embedding_count -= 1
                elsif !stack.last[:isolate] && stack.length > 1
                  stack.pop
                end
              end
            when :BN
              levels[index] = current[:level]
            else
              levels[index] = current[:level]
              resolved[index] = current[:override] if current[:override]
            end
          end

          [levels, resolved]
        end

        # The characters that take part in isolating run sequences (UAX #9
        # rules X9 and BD13): all characters except the ones removed by
        # rule X9 and isolate initiators without a matching PDI in the
        # paragraph. Unmatched isolate initiators keep the level assigned
        # during the explicit phase.
        #
        # @return [Array(Array<Integer>, Hash)] indices of kept characters
        #   and a map of isolate initiator index to matching PDI index
        def sequence_structure(types)
          matching_pdi = {}
          stack = []
          types.each_with_index do |type, index|
            next if removed?(type)

            case type
            when :LRI, :RLI, :FSI
              stack.push(index)
            when :PDI
              matching_pdi[stack.pop] = index unless stack.empty?
            end
          end

          kept = (0...types.length).reject do |index|
            removed?(types[index]) ||
              unmatched_initiator?(types, matching_pdi, index)
          end

          [kept, matching_pdi]
        end

        # UAX #9 rule BD13: isolating run sequences.
        #
        # @return [Array<Array<Integer>>] sequences of character indices
        def isolating_run_sequences(types, levels, kept, matching_pdi)
          return [] if kept.empty?

          # Level runs over the kept characters.
          level_runs = []
          kept.each do |i|
            if level_runs.empty? || levels[i] != levels[level_runs.last.last]
              level_runs << [i]
            else
              level_runs.last << i
            end
          end

          run_of = {}
          level_runs.each_with_index do |run, run_index|
            run.each { |i| run_of[i] = run_index }
          end

          # Chain level runs into isolating run sequences.
          following = {}
          pointed = {}
          level_runs.each_with_index do |run, run_index|
            pdi = matching_pdi[run.last]
            next unless pdi && run_of[pdi] != run_index

            following[run_index] = run_of[pdi]
            pointed[run_of[pdi]] = true
          end

          sequences = []
          level_runs.each_with_index do |run, run_index|
            next if pointed[run_index]

            sequence = []
            current = run_index
            while current
              sequence.concat(level_runs[current])
              current = following[current]
            end
            sequences << sequence
          end
          sequences
        end

        def unmatched_initiator?(types, matching_pdi, index)
          ISOLATE_INITIATORS.include?(types[index]) &&
            !matching_pdi.key?(index)
        end

        def removed?(type)
          REMOVED_CLASSES.include?(type)
        end

        # The bidi type (:L or :R) of the start or end of an isolating run
        # sequence (UAX #9 rule X10). Neighboring characters are determined
        # skipping over characters removed by rule X9.
        def sequence_bound_type(
          levels, sequence, paragraph_level, boundary, at_start
        )
          own_level = levels[at_start ? sequence.first : sequence.last]
          other_level =
            if at_start
              neighbor = boundary.reverse.find { |i| i < sequence.first }
              neighbor ? levels[neighbor] : paragraph_level
            else
              neighbor = boundary.find { |i| i > sequence.last }
              neighbor ? levels[neighbor] : paragraph_level
            end
          [own_level, other_level].max.odd? ? :R : :L
        end

        # UAX #9 rules W1--W7: weak type resolution.
        def resolve_weak(types, levels, sequences, paragraph_level, boundary)
          sequences.each do |sequence|
            sor = sequence_bound_type(
              levels, sequence, paragraph_level, boundary, true,
            )

            # W1: non-spacing marks take the type of the previous
            # character in the isolating run sequence.
            previous = sor
            sequence.each do |index|
              if types[index] == :NSM
                types[index] =
                  if ISOLATE_FORMATTERS.include?(previous)
                    :ON
                  else
                    previous
                  end
              end
              previous = types[index]
            end

            # W2: European numbers preceded by an Arabic letter become
            # Arabic numbers.
            sequence.each_with_index do |index, pos|
              next unless types[index] == :EN

              strong = sor
              (pos - 1).downto(0) do |p|
                type = types[sequence[p]]
                if STRONG_CLASSES.include?(type)
                  strong = type
                  break
                end
              end
              types[index] = :AN if strong == :AL
            end

            # W3: Arabic letters become R.
            sequence.each do |index|
              types[index] = :R if types[index] == :AL
            end

            # W4: separators between numbers of the same type become
            # numbers of that type.
            sequence.each_with_index do |index, pos|
              type = types[index]
              prev = pos.positive? ? types[sequence[pos - 1]] : nil
              nxt = pos + 1 < sequence.length ? types[sequence[pos + 1]] : nil
              if type == :ES && prev == :EN && nxt == :EN
                types[index] = :EN
              elsif type == :CS && prev == nxt &&
                  (prev == :EN || prev == :AN)
                types[index] = prev
              end
            end

            # W5: European terminators adjacent to European numbers
            # become European numbers.
            sequence.each_with_index do |index, pos|
              next unless types[index] == :ET

              before = pos.positive? ? types[sequence[pos - 1]] : nil
              stop = pos
              stop += 1 while stop < sequence.length &&
                types[sequence[stop]] == :ET
              after = stop < sequence.length ? types[sequence[stop]] : nil
              if before == :EN || after == :EN
                (pos...stop).each { |p| types[sequence[p]] = :EN }
              end
            end

            # W6: remaining separators and terminators become ON.
            sequence.each do |index|
              types[index] = :ON if %i[ET ES CS].include?(types[index])
            end

            # W7: European numbers preceded by L become L.
            sequence.each_with_index do |index, pos|
              next unless types[index] == :EN

              strong = sor
              (pos - 1).downto(0) do |p|
                type = types[sequence[p]]
                if %i[L R].include?(type)
                  strong = type
                  break
                end
              end
              types[index] = :L if strong == :L
            end
          end
        end

        # UAX #9 rule N0: paired brackets take the direction of their
        # enclosed or surrounding strong text.
        def resolve_brackets(
          types, levels, sequences, codepoints, paragraph_level, boundary
        )
          sequences.each do |sequence|
            pairs = bracket_pairs(sequence, codepoints)
            pairs.sort_by!(&:first)

            pairs.each do |(open_index, close_index)|
              embedding = levels[open_index].odd? ? :R : :L

              enclosed_strong = []
              inside = false
              sequence.each do |index|
                if index == open_index
                  inside = true
                  next
                end
                break if index == close_index
                next unless inside

                strong = strong_or_number(types[index])
                enclosed_strong << strong if strong
              end

              if enclosed_strong.include?(embedding)
                types[open_index] = embedding
                types[close_index] = embedding
              elsif enclosed_strong.any?
                preceding =
                  sequence_bound_type(
                    levels, sequence, paragraph_level, boundary, true,
                  )
                pos = sequence.index(open_index)
                (pos - 1).downto(0) do |p|
                  strong = strong_or_number(types[sequence[p]])
                  if strong
                    preceding = strong
                    break
                  end
                end
                opposite = embedding == :R ? :L : :R
                resolved = preceding == opposite ? opposite : embedding
                types[open_index] = resolved
                types[close_index] = resolved
              end
            end
          end
        end

        # UAX #9 rule BD16: identify bracket pairs in an isolating run
        # sequence.
        def bracket_pairs(sequence, codepoints)
          pairs = []
          stack = []
          sequence.each do |index|
            codepoint = codepoints[index]
            if PAIRED_BRACKETS.key?(codepoint)
              stack.push(index)
            elsif CLOSE_BRACKETS.key?(codepoint)
              (stack.length - 1).downto(0) do |s|
                if PAIRED_BRACKETS[codepoints[stack[s]]] == codepoint
                  pairs << [stack[s], index]
                  stack = stack[0...s]
                  break
                end
              end
              break if pairs.length >= 63
            end
          end
          pairs
        end

        # Strong type of a character for N0/N1 purposes: EN and AN are
        # treated as R.
        def strong_or_number(type)
          case type
          when :L then :L
          when :R, :EN, :AN then :R
          end
        end

        # UAX #9 rules N1--N2: neutral type resolution.
        def resolve_neutral(types, levels, sequences, paragraph_level, boundary)
          sequences.each do |sequence|
            sor = sequence_bound_type(
              levels, sequence, paragraph_level, boundary, true,
            )
            eot = sequence_bound_type(
              levels, sequence, paragraph_level, boundary, false,
            )

            strong_before = sor
            pos = 0
            while pos < sequence.length
              index = sequence[pos]
              strong = strong_or_number(types[index])
              if strong
                strong_before = strong
                pos += 1
              else
                stop = pos
                stop += 1 while stop < sequence.length &&
                  strong_or_number(types[sequence[stop]]).nil?
                strong_after =
                  if stop < sequence.length
                    strong_or_number(types[sequence[stop]])
                  else
                    eot
                  end
                direction =
                  if strong_before == strong_after
                    strong_before
                  elsif levels[index].odd?
                    :R
                  else
                    :L
                  end
                (pos...stop).each { |p| types[sequence[p]] = direction }
                pos = stop
              end
            end
          end
        end

        # UAX #9 rules I1--I2: implicit level resolution.
        def resolve_implicit(types, levels)
          types.each_with_index do |type, index|
            if levels[index].even?
              levels[index] += 1 if type == :R
              levels[index] += 2 if %i[EN AN].include?(type)
            elsif %i[L EN AN].include?(type)
              levels[index] += 1
            end
          end
        end

        # UAX #9 rule L1: reset segment/paragraph separators and trailing
        # whitespace and isolate formatting characters to the paragraph
        # level. Characters removed by rule X9 are treated as transparent
        # when determining trailing whitespace.
        def reset_line_ends(types, levels, paragraph_level)
          resettable = ->(type) {
            type == :WS || ISOLATE_FORMATTERS.include?(type)
          }

          types.each_with_index do |type, index|
            next unless type == :S || type == :B

            levels[index] = paragraph_level
            back = index - 1
            while back >= 0 &&
                (resettable.call(types[back]) || removed?(types[back]))
              levels[back] = paragraph_level
              back -= 1
            end
          end

          back = levels.length - 1
          while back >= 0 &&
              (resettable.call(types[back]) || removed?(types[back]))
            levels[back] = paragraph_level
            back -= 1
          end
        end

        # Levels for characters removed from the sequence by rule X9
        # (explicit formatting characters and BN). They take the level of
        # the nearest following character that is not removed, or the
        # paragraph level when no such character follows.
        def assign_removed_levels(types, levels, paragraph_level)
          following = paragraph_level
          (types.length - 1).downto(0) do |index|
            if removed?(types[index])
              levels[index] = following
            else
              following = levels[index]
            end
          end
        end
      end
    end
  end
end
