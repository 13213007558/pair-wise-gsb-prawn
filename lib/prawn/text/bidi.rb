# frozen_string_literal: true

module Prawn
  module Text
    # UAX #9 Unicode Bidirectional Algorithm (Unicode 15.1.0).
    #
    # This class intentionally performs no shaping. It determines embedding
    # levels and visual order while retaining logical character indices.
    # @private
    class Bidi
      UNICODE_VERSION = '15.1.0'

      Position = Struct.new(:index, :logical_index, :char, :type, :level, :removed,
                            :mirror, :width, :base_width, :fragment,
                            :fragment_index, :trailing,
                            keyword_init: true)

      CONTROLS = {
        0x202A => :LRE, 0x202B => :RLE, 0x202C => :PDF,
        0x202D => :LRO, 0x202E => :RLO,
        0x2066 => :LRI, 0x2067 => :RLI, 0x2068 => :FSI, 0x2069 => :PDI,
      }.freeze

      EXPLICIT_REMOVED = %i[LRE RLE LRO RLO PDF LRI RLI FSI PDI].freeze
      INVISIBLE_TYPES = %i[LRM RLM LRE RLE LRO RLO PDF LRI RLI FSI PDI].freeze

      STRONG_AL_SCRIPTS = %w[
        Adlam Arabic Hanifi_Rohingya Nko Syriac Thaana Mandaic Samaritan
        Hatran Manichaean Nabataean Old_North_Arabian Old_South_Arabian
        Palmyrene Psalter_Pahlavi Imperial_Aramaic Inscriptional_Pahlavi
        Inscriptional_Parthian Chorasmian Elymaic Yezidi
      ].map { |name| /\p{#{name}}/ }.freeze

      STRONG_R_SCRIPTS = %w[
        Hebrew Ugaritic Old_South_Arabian Phoenician
      ].map { |name| /\p{#{name}}/ }.freeze

      AN_RANGES = [
        0x0600..0x0604, 0x0660..0x0669, 0x07C0..0x07C9,
        0x0890..0x0891, 0x0898..0x089F, 0x2048..0x2049,
        (0x10E60..0x10E69),
        (0x10D30..0x10D39),
      ].freeze

      CS_CHARS = [0x002C, 0x002E, 0x003A, 0x003B, 0x00A0,
                  0x002F, 0x2044, 0x060C, 0x061B, 0xFE13, 0xFE14,
                  0xFE50, 0xFE54, 0xFF0C, 0xFF0E, 0xFF1A,
                  0xFF1B].freeze

      ES_CHARS = [0x002B, 0x002D, 0x207A, 0x207B, 0x208A, 0x208B,
                  0xFE62, 0xFE63, 0xFF0B, 0xFF0D].freeze

      ET_TYPES = %i[Sc].freeze

      BN_CHARS = [0x0000..0x0008, 0x000E..0x001B,
                  0x007F..0x009F].freeze

      MIRRORED = {
        '(' => ')', ')' => '(', '[' => ']', ']' => '[',
        '{' => '}', '}' => '{', '<' => '>', '>' => '<',
        '«' => '»', '»' => '«', '‹' => '›', '›' => '‹',
        0x2045.chr(::Encoding::UTF_8) => 0x2046.chr(::Encoding::UTF_8),
        0x2046.chr(::Encoding::UTF_8) => 0x2045.chr(::Encoding::UTF_8),
      }.freeze

      BRACKET_PAIRS = MIRRORED.merge(
        '(' => ')', ')' => '(', '[' => ']', ']' => '[',
        '{' => '}', '}' => '{',
        '«' => '»', '»' => '«', '‹' => '›', '›' => '‹',
        0x2045.chr(::Encoding::UTF_8) => 0x2046.chr(::Encoding::UTF_8),
        0x2046.chr(::Encoding::UTF_8) => 0x2045.chr(::Encoding::UTF_8),
        '⟦' => '⟧', '⟧' => '⟦', '⟨' => '⟩', '⟩' => '⟨',
        '⟪' => '⟫', '⟫' => '⟪', '⟬' => '⟭', '⟭' => '⟬',
      ).freeze

      def self.base_level(text, direction = nil)
        direction == :rtl ? 1 : direction == :ltr ? 0 : paragraph_direction(text)
      end

      def self.paragraph_direction(text)
        text.each_char do |char|
          type = character_type(char.codepoints.first)
          return 0 if type == :L
          return 1 if %i[R AL].include?(type)
        end
        0
      end

      def self.visual_positions(text, direction: nil)
        new(text, direction).visual_positions
      end

      def self.visible_text(text, direction: nil)
        visual_positions(text, direction: direction).reject(&:removed).map(&:char).join
      end

      def self.logical_text_without_controls(text)
        text.each_char.reject do |char|
          INVISIBLE_TYPES.include?(character_type(char.codepoints.first))
        end.join
      end

      def self.character_type(codepoint)
        char = codepoint.chr(::Encoding::UTF_8)
        type = explicit_type(codepoint, char) and return type

        return :NSM if /\p{M}/.match?(char)
        return :BN if /\p{Cf}/.match?(char) || bn_codepoint?(codepoint)
        return :B if [0x000A, 0x000D, 0x001C, 0x001D, 0x001E,
                      0x0085, 0x2028, 0x2029].include?(codepoint)
        return :S if [0x0009, 0x000B, 0x001F, 0x2027].include?(codepoint)
        return :WS if whitespace?(codepoint, char)
        return :AN if an_codepoint?(codepoint)
        return :EN if /\p{Nd}/.match?(char)
        return :ES if ES_CHARS.include?(codepoint)
        return :ET if ET_TYPES.any? { |type| /\p{#{type}}/.match?(char) }
        return :CS if cs_codepoint?(codepoint)
        return :AL if strong_al?(char)
        return :R if strong_r?(char)
        return :L if /\p{L}/.match?(char)

        :ON
      end

      def self.explicit_type(codepoint, char)
        return CONTROLS[codepoint] if CONTROLS.key?(codepoint)
        return :RLM if codepoint == 0x200F
        return :LRM if codepoint == 0x200E
        return :AL if codepoint == 0x061C
        return :R if strong_r?(char)
        return :AL if strong_al?(char)
        nil
      end

      class << self
        private

        def strong_al?(char)
          STRONG_AL_SCRIPTS.any? { |regexp| regexp.match?(char) }
        end

        def strong_r?(char)
          STRONG_R_SCRIPTS.any? { |regexp| regexp.match?(char) }
        end

        def an_codepoint?(codepoint)
          AN_RANGES.any? { |range| range.include?(codepoint) }
        end

        def cs_codepoint?(codepoint)
          CS_CHARS.include?(codepoint)
        end

        def bn_codepoint?(codepoint)
          BN_CHARS.any? { |entry| entry === codepoint }
        end

        def whitespace?(codepoint, char)
          [0x0020, 0x2000..0x200A, 0x202F, 0x205F, 0x3000].any? do |entry|
            entry === codepoint
          end || char =~ /\p{Zl}|\p{Zp}/
        end
      end

      def initialize(text, direction)
        @paragraph_level =
          case direction
          when :ltr then 0
          when :rtl then 1
          else self.class.paragraph_direction(text)
          end
        @positions = []
        @chars = text.each_char.to_a
        @types = @chars.map { |char| self.class.send(:character_type, char.codepoints.first) }
        @original_types = @types.dup
        @levels = Array.new(@chars.length, @paragraph_level)
        @removed = Array.new(@chars.length, false)
        run_explicit_rules
        build_positions

        isolating_run_sequences.each do |indices|
          apply_bracket_rules(indices)
          apply_weak_rules(indices)
          apply_neutral_rules(indices)
          apply_implicit_levels(indices)
        end

        apply_paragraph_line_rules
        build_positions
      end

      def paragraph_level
        @paragraph_level
      end

      def visual_positions
        ordered = @positions.reject(&:removed)
        max_level = [ordered.map(&:level).max || @paragraph_level, 1].max
        max_level.downto(1) do |level|
          ordered = ordered.chunk_while do |left, right|
            (left.level >= level) == (right.level >= level)
          end.flat_map { |group| group.first.level >= level ? group.reverse : group }
        end
        ordered.each do |position|
          position.mirror = position.level.odd? && MIRRORED.key?(position.char)
        end
        ordered.each_with_index { |position, index| position.logical_index = index }
        ordered
      end

      private

      def run_explicit_rules
        stack = [{ level: @paragraph_level, override: nil, isolate: false }]

        @types.each_with_index do |type, index|
          if %i[LRM RLM].include?(type)
            @removed[index] = true
            @types[index] = :BN
          end

          case @original_types[index]
          when :LRE, :RLE, :LRO, :RLO, :LRI, :RLI, :FSI
            handle_isolate_start(type, index, stack)
          when :PDF
            unless stack.one?
              stack.pop unless stack.last[:isolate]
            end
          when :PDI
            if stack.length > 1 && stack.any? { |entry| entry[:isolate] }
              stack.pop until stack.last[:isolate]
              stack.pop
            end
            @removed[index] = true
          when *EXPLICIT_REMOVED
            @removed[index] = true
          end

          @levels[index] = stack.last[:level]
          @types[index] = stack.last[:override] if stack.last[:override]
        end
      end

      def handle_isolate_start(type, index, stack)
        resolved_type =
          if type == :FSI
            matching = matching_pdi(index, 0)
            segment = @chars[index + 1...matching].join
            self.class.paragraph_direction(segment).zero? ? :LRI : :RLI
          else
            type
          end

        level =
          case resolved_type
          when :LRI then @paragraph_level
          when :RLI then @paragraph_level.odd? ? @paragraph_level : @paragraph_level + 1
          when :LRE, :LRO then next_even_level(@levels[index])
          when :RLE, :RLO then next_explicit_odd_level(@levels[index])
          end
        override = { LRO: :L, RLO: :R, LRE: nil, RLE: nil,
                     LRI: nil, RLI: nil, FSI: nil }.fetch(type)
        stack << { level: level, override: override,
                   isolate: isolate_type?(resolved_type) }
      end

      def matching_pdi(index, isolate_count)
        depth = 0
        (index + 1...@types.length).find do |candidate|
          if isolate_type?(@original_types[candidate])
            depth += 1
          elsif @original_types[candidate] == :PDI && depth.positive?
            depth -= 1
            true
          end
        end || @types.length
      end

      def isolate_type?(type)
        %i[LRI RLI FSI].include?(type)
      end

      def next_odd_level(level)
        level.even? ? level + 1 : level + 2
      end

      def next_explicit_odd_level(level)
        level.even? ? level + 1 : level + 2
      end

      def isolating_run_sequences
        sequences = []
        initiator = { LRI: 0, RLI: 1, FSI: 0 }

        @types.each_index do |start|
          next if @removed[start]

          type = @original_types[start]
          next unless start.zero? || initiator.key?(type)

          sequence = [start]
          index = start + 1
          while index < @types.length
            original = @original_types[index]
            if initiator.key?(original)
              sequence << index
              matching = matching_pdi(index, 0)
              sequence << matching if matching < @types.length
              index = matching + 1
            elsif original == :PDI
              sequence << index
              index = @types.length
            else
              sequence << index unless @removed[index]
              index += 1
            end
          end
          sequences << sequence.uniq
        end
        sequences
      end

      def apply_bracket_rules(indices)
        stack = []
        pairs = []
        indices.each do |index|
          next if @removed[index]

          char = @chars[index]
          if opening_bracket?(char) && BRACKET_PAIRS.key?(char)
            stack << [char, index]
          elsif closing_bracket?(char)
            pair_index = stack.rindex { |opening, _| BRACKET_PAIRS[opening] == char }
            next unless pair_index

            _opening, open_index = stack.delete_at(pair_index)
            pairs << [open_index, index]
          end
        end

        pairs.first(63).each do |open_index, close_index|
          strong = strong_bracket_direction(open_index, indices) ||
            strong_bracket_direction(close_index, indices)
          if strong
            @types[open_index] = strong
            @types[close_index] = strong
          end
        end
      end

      def opening_bracket?(char)
        !['⟧', '⟩', '⟫', '⟭', ')', ']', '}', '>', '»', '›'].include?(char)
      end

      def closing_bracket?(char)
        BRACKET_PAIRS.value?(char) && !opening_bracket?(char)
      end

      def strong_bracket_direction(index, indices)
        position = indices.index(index)
        indices[0...position].reverse_each do |candidate|
          next if @removed[candidate] || @types[candidate] == :BN

          return :R if %i[R AL AN].include?(@types[candidate])
          return :L if %i[L EN].include?(@types[candidate])
        end
        @paragraph_level.zero? ? :L : :R
      end

      def apply_weak_rules(indices)
        indices.each do |index|
          next if @removed[index]

          if @types[index] == :NSM
            @types[index] = previous_type(index, indices)
          elsif @types[index] == :EN && immediate_non_boundary_neutral(index, indices) == :AL
            @types[index] = :AN
          end
        end

        indices.each { |index| @types[index] = :R if @types[index] == :AL }

        adjacent_type_runs(indices, %i[ES]).each do |run|
          before = @types[run.first - 1]
          after = @types[run.last + 1]
          resolved = before == :EN && after == :EN ? :EN :
            before == :AN && after == :AN ? :AN : :ON
          run.each { |index| @types[index] = resolved }
        end

        adjacent_type_runs(indices, %i[CS]).each do |run|
          before = @types[run.first - 1]
          after = @types[run.last + 1]
          resolved = before == :EN && after == :EN ? :EN :
            before == :AN && after == :AN ? :AN : :ON
          run.each { |index| @types[index] = resolved }
        end

        adjacent_type_runs(indices, %i[ET]).each do |run|
          if @types[run.first - 1] == :EN || @types[run.last + 1] == :EN
            run.each { |index| @types[index] = :EN }
          end
        end

        indices.each do |index|
          next if @removed[index]

          @types[index] = :ON if @types[index] == :ES || @types[index] == :ET
          @types[index] = :AN if @types[index] == :EN &&
            immediate_non_boundary_neutral(index, indices) == :AL
        end
      end

      def previous_type(index, indices)
        position = indices.index(index)
        indices[0...position].reverse_each do |candidate|
          return @levels[candidate].odd? ? :R : :L if @removed[candidate]
          return @types[candidate] unless @types[candidate] == :BN
        end
        :R if @paragraph_level.odd?
      end

      def immediate_non_boundary_neutral(index, indices)
        position = indices.index(index)
        indices[0...position].reverse_each do |candidate|
          next if @types[candidate] == :BN

          return @types[candidate]
        end
        nil
      end

      def previous_strong_type(index, indices)
        position = indices.index(index)
        indices[0...position].reverse_each do |candidate|
          next if @removed[candidate] || %i[BN NSM].include?(@types[candidate])

          return @types[candidate] if %i[R AL L EN AN].include?(@types[candidate])
        end
        nil
      end

      def adjacent_type_runs(indices, types)
        grouped = indices.chunk_while do |left, right|
          left.succ == right && types.include?(@types[left]) &&
            types.include?(@types[right])
        end
        grouped.select { |run| run.all? { |index| types.include?(@types[index]) } }
      end

      def apply_neutral_rules(indices)
        neutral = []
        runs = []
        indices.each do |index|
          if !@removed[index] && %i[B S WS ON].include?(@types[index])
            neutral << index
          elsif !neutral.empty?
            runs << neutral
            neutral = []
          end
        end
        runs << neutral unless neutral.empty?

        runs.each do |run|
          left = neutral_neighbor(run.first, indices, -1)
          right = neutral_neighbor(run.last, indices, 1)
          resolved =
            if %i[R N].include?(left) && %i[R N].include?(right)
              :R
            elsif left == :L && right == :L
              :L
            else
              @paragraph_level.zero? ? :L : :R
            end
          run.each do |index|
            @types[index] = resolved unless %i[B S].include?(@types[index])
          end
        end
      end

      def neutral_neighbor(index, indices, direction)
        position = indices.index(index) + direction
        while position >= 0 && position < indices.length
          candidate = indices[position]
          unless @removed[candidate]
            return :R if %i[R AL].include?(@types[candidate])
            return :N if %i[AN EN].include?(@types[candidate])
            return :L if @types[candidate] == :L
          end
          position += direction
        end
        nil
      end

      def apply_implicit_levels(indices)
        indices.each do |index|
          next if @removed[index]

          level = @levels[index]
          @levels[index] =
            case @types[index]
            when :R then level.odd? ? level : level + 1
            when :L then level.odd? ? level + 1 : level
            when :EN, :AN then level.odd? ? level + 1 : level
            else level
            end
        end
      end

      def next_even_level(level)
        level.odd? ? level + 1 : level
      end

      def apply_paragraph_line_rules
        trailing = true
        @chars.length.times.reverse_each do |index|
          type = @original_types[index]
          if type == :B || type == :S
            @levels[index] = @paragraph_level
            trailing = true
          elsif trailing && type == :WS
            @levels[index] = @paragraph_level
          else
            trailing = false
          end
        end
      end

      def build_positions
        @positions = @chars.each_with_index.map do |char, index|
          Position.new(
            index: index,
            logical_index: nil,
            char: char,
            type: @types[index],
            level: @levels[index],
            removed: @removed[index] || EXPLICIT_REMOVED.include?(@original_types[index]),
            mirror: false,
            base_width: nil,
            fragment: nil,
            fragment_index: nil,
            trailing: false,
          )
        end
      end
    end
  end
end
