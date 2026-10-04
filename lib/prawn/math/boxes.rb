# frozen_string_literal: true

module Prawn
  module Math
    # A run of text in the math font.
    class TextBox < Box
      attr_reader :string, :size

      def initialize(layout, string, style_level, bold: false, atom: nil,
                     size: nil)
        @string = string
        @size = size || layout.size_for(style_level)
        @bold = bold
        @atom = atom || self.class.atom_for(string)
        width, height, depth = layout.measure(string, @size, bold)
        super(width, height, depth)
      end

      # Classifies a literal for inter-atom spacing.
      def self.atom_for(string)
        stripped = string.strip
        if stripped.length == 1
          return :rel if Prawn::Math::RELATION_CHARS.include?(stripped)
          return :bin if Prawn::Math::BINARY_CHARS.include?(stripped)
        end
        :ord
      end

      attr_reader :atom

      def kind
        :text
      end

      def label
        @string.inspect
      end

      def render(pdf, x, baseline)
        pdf.font(
          Prawn::Math::FONT_FAMILY,
          style: @bold ? :bold : :normal,
          size: @size,
        ) do
          pdf.draw_text(@string, at: [x, baseline])
        end
      end
    end

    # An empty box with a fixed width (explicit spacing).
    class SpaceBox < Box
      def initialize(width)
        super(width, 0.0, 0.0)
      end

      def kind
        :space
      end

      def render(_pdf, _x, _baseline)
        # nothing to draw
      end
    end

    # Horizontal composition of boxes with TeX-inspired inter-atom
    # spacing (medium around relations/binary operators, thin around
    # large operators; no spacing in script styles).
    class RowBox < Box
      # Glue widths in em of the current style size.
      GLUE = { thin: 1.0 / 6.0, med: 2.0 / 9.0 }.freeze

      def initialize(layout, items, style_level)
        em = layout.size_for(style_level)
        spaced = %i[display text].include?(style_level)
        @items = []
        x = 0.0
        prev = nil
        items.each do |box|
          x += glue(prev.atom, box.atom) * em if prev && spaced
          @items << [box, x]
          x += box.width
          prev = box
        end
        height = items.map(&:height).max || 0.0
        depth = items.map(&:depth).max || 0.0
        super(x, height, depth)
      end

      def kind
        :row
      end

      def children
        @items.map { |box, dx| [box, dx, 0.0] }
      end

      def render(pdf, x, baseline)
        @items.each { |box, dx| box.render(pdf, x + dx, baseline) }
      end

      private

      def glue(left, right)
        return GLUE[:med] if left == :rel || right == :rel
        if (left == :ord && right == :bin) || (left == :bin && right == :ord)
          return GLUE[:med]
        end
        return GLUE[:thin] if left == :op || right == :op

        0.0
      end
    end

    # A fraction: numerator above a horizontal rule, denominator below.
    # The rule sits on the math axis (0.25em). Clearance between the
    # rule and the numerator/denominator is 3 rule thicknesses in
    # display style and 1.5 otherwise, so nested fractions never touch
    # the bar.
    class FracBox < Box
      # Thickness of the fraction rule in points.
      attr_reader :rule

      # y-offset of the rule relative to the fraction's baseline.
      attr_reader :axis

      # Numerator and denominator boxes.
      attr_reader :num, :den

      def initialize(layout, num, den, style_level)
        em = layout.size_for(style_level)
        @axis = 0.25 * em
        @rule = [0.045 * em, 0.3].max
        gap = (style_level == :display ? 3.0 : 1.5) * @rule
        pad = 0.1 * em
        @num = num
        @den = den
        inner = [num.width, den.width].max
        @num_x = pad + (inner - num.width) / 2.0
        @den_x = pad + (inner - den.width) / 2.0
        @num_off = @axis + @rule / 2.0 + gap + num.depth
        @den_off = @axis - @rule / 2.0 - gap - den.height
        width = inner + 2.0 * pad
        height = @num_off + num.height
        depth = -@den_off + den.depth
        super(width, height, depth)
      end

      def kind
        :frac
      end

      def children
        [[@num, @num_x, @num_off], [@den, @den_x, @den_off]]
      end

      def render(pdf, x, baseline)
        pdf.save_graphics_state do
          pdf.line_width = @rule
          pdf.stroke_line(
            [x, baseline + @axis],
            [x + width, baseline + @axis],
          )
        end
        @num.render(pdf, x + @num_x, baseline + @num_off)
        @den.render(pdf, x + @den_x, baseline + @den_off)
      end
    end

    # A square root. The radical sign is drawn as vector lines: a surd
    # on the left plus an overline that spans the whole radicand (plus a
    # small tail), so the radicand is always fully covered regardless of
    # its height or nesting.
    class SqrtBox < Box
      # The radicand box.
      attr_reader :rad

      # Thickness of the drawn strokes in points.
      attr_reader :rule

      def initialize(layout, rad, style_level)
        em = layout.size_for(style_level)
        @rule = [0.045 * em, 0.3].max
        clearance = @rule + 0.08 * em
        @surd_w = 0.55 * em
        @lead = 0.08 * em
        @tail = 0.12 * em
        @rad = rad
        @rad_x = @surd_w + @lead
        overline_y = rad.height + clearance + @rule / 2.0
        width = @rad_x + rad.width + @tail
        height = overline_y + @rule / 2.0
        depth = rad.depth + 0.05 * em
        super(width, height, depth)
      end

      def kind
        :sqrt
      end

      def children
        [[@rad, @rad_x, 0.0]]
      end

      def render(pdf, x, baseline)
        top_y = baseline + height - @rule / 2.0
        pdf.save_graphics_state do
          pdf.line_width = @rule
          pdf.join_style(:round)
          pdf.move_to(x + 0.05 * @surd_w, baseline + 0.3 * height)
          pdf.line_to(x + 0.4 * @surd_w, baseline - depth + @rule / 2.0)
          pdf.line_to(x + @surd_w, top_y)
          pdf.line_to(x + width, top_y)
          pdf.stroke
        end
        @rad.render(pdf, x + @rad_x, baseline)
      end
    end

    # A base with a superscript and/or a subscript. Script positions
    # follow TeX-inspired shifts; when both scripts are present the
    # superscript is raised until the gap between the superscript's
    # bottom and the subscript's top is at least 4 rule thicknesses.
    class ScriptBox < Box
      # Extra space between the base and its scripts, in points
      # (TeX's \scriptspace).
      SCRIPT_SPACE = 0.5

      # Base, superscript and subscript boxes (nil when absent).
      attr_reader :base, :sup, :sub

      # Baseline offsets: superscript above, subscript below.
      attr_reader :sup_off, :sub_off

      def initialize(layout, base, sup:, sub:, style_level:)
        em = layout.size_for(style_level)
        script_em = layout.size_for(layout.script_style(style_level))
        rule = [0.045 * em, 0.3].max
        @base = base
        @sup = sup
        @sub = sub
        @sup_off = sup ? [0.35 * em, base.height - 0.5 * script_em].max : 0.0
        @sub_off = sub ? [0.18 * em, base.depth + 0.3 * script_em].max : 0.0
        if sup && sub
          min_gap = 4.0 * rule
          sup_bottom = @sup_off - sup.depth
          sub_top = sub.height - @sub_off
          deficit = min_gap - (sup_bottom - sub_top)
          @sup_off += deficit if deficit.positive?
        end
        script_x = base.width + SCRIPT_SPACE
        width = script_x + [sup&.width || 0.0, sub&.width || 0.0].max
        height = [base.height, sup ? @sup_off + sup.height : 0.0].max
        depth = [base.depth, sub ? @sub_off + sub.depth : 0.0].max
        super(width, height, depth)
      end

      def kind
        :scripts
      end

      def children
        list = [[@base, 0.0, 0.0]]
        script_x = @base.width + SCRIPT_SPACE
        list << [@sup, script_x, @sup_off] if @sup
        list << [@sub, script_x, -@sub_off] if @sub
        list
      end

      def render(pdf, x, baseline)
        @base.render(pdf, x, baseline)
        script_x = x + @base.width + SCRIPT_SPACE
        @sup&.render(pdf, script_x, baseline + @sup_off)
        @sub&.render(pdf, script_x, baseline - @sub_off)
      end
    end

    # A large operator (sum, product, integral) in display style, with
    # its limits centered above and below the glyph.
    class BigOpBox < Box
      # Glyph enlargement in display style.
      DISPLAY_SCALE = 1.6

      # The operator glyph box and the limit boxes (nil when absent).
      attr_reader :op, :under, :over

      def initialize(layout, glyph, under:, over:, style_level:)
        em = layout.size_for(style_level)
        @op = TextBox.new(
          layout, glyph, style_level,
          atom: :op, size: em * DISPLAY_SCALE,
        )
        @under = under
        @over = over
        gap = 0.15 * em
        pad = 0.05 * em
        width = [@op.width, under&.width || 0.0, over&.width || 0.0].max +
                (2.0 * pad)
        @op_x = (width - @op.width) / 2.0
        @over_off = over ? @op.height + gap + over.depth : 0.0
        @under_off = under ? @op.depth + gap + under.height : 0.0
        height = @op.height + (over ? gap + over.depth + over.height : 0.0)
        depth = @op.depth + (under ? gap + under.height + under.depth : 0.0)
        super(width, height, depth)
      end

      def atom
        :op
      end

      def kind
        :bigop
      end

      def children
        list = [[@op, @op_x, 0.0]]
        if @over
          list << [@over, (width - @over.width) / 2.0, @over_off]
        end
        if @under
          list << [@under, (width - @under.width) / 2.0, -@under_off]
        end
        list
      end

      def render(pdf, x, baseline)
        @op.render(pdf, x + @op_x, baseline)
        if @over
          @over.render(pdf, x + (width - @over.width) / 2.0,
                       baseline + @over_off)
        end
        if @under
          @under.render(pdf, x + (width - @under.width) / 2.0,
                        baseline - @under_off)
        end
      end
    end
  end
end
