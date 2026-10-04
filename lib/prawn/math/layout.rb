# frozen_string_literal: true

module Prawn
  module Math
    # Turns expression trees into laid-out boxes. Holds the document
    # (for font metrics) and the base font size.
    class Layout
      # Expression tags recognized in arrays.
      TAGS = %i[row t b sym frac sqrt sup sub subsup bigop space display
                inline].freeze

      attr_reader :pdf, :base_size

      def initialize(pdf, base_size)
        @pdf = pdf
        @base_size = base_size
      end

      # Font size for a style level.
      def size_for(style)
        base_size * Prawn::Math::STYLE_SCALE.fetch(style)
      end

      # Style used for scripts of the given style.
      def script_style(style)
        %i[display text].include?(style) ? :script : :scriptscript
      end

      # Style used for fraction numerator/denominator of the given style.
      def frac_style(style)
        style == :display ? :text : script_style(style)
      end

      # Measures a string in the math font.
      #
      # @return [Array(Number, Number, Number)] width, height (above
      #   baseline), depth (below baseline) in points
      def measure(string, size, bold)
        pdf.font(Prawn::Math::FONT_FAMILY, style: bold ? :bold : :normal,
                 size: size) do
          @measured = [pdf.width_of(string), pdf.font.ascender,
                       pdf.font.descender]
        end
        @measured
      end

      # Builds a box from any expression node.
      #
      # @return [Prawn::Math::Box]
      def build(expr, style)
        case expr
        when Box
          expr
        when String
          TextBox.new(self, expr, style)
        when Symbol
          glyph = Prawn::Math::SYMBOLS[expr]
          unless glyph
            raise ArgumentError, "unknown math symbol: #{expr.inspect}"
          end
          TextBox.new(self, glyph, style)
        when Numeric
          TextBox.new(self, expr.to_s, style)
        when Array
          tag = expr.first
          if tag.is_a?(Symbol) && TAGS.include?(tag)
            build_tagged(tag, expr[1..], style)
          else
            build_row(expr, style)
          end
        else
          raise ArgumentError,
                "unsupported math expression: #{expr.inspect}"
        end
      end

      private

      def build_tagged(tag, args, style)
        case tag
        when :row
          build_row(args, style)
        when :t
          TextBox.new(self, args[0].to_s, style, bold: args[1] == :bold)
        when :b
          TextBox.new(self, args[0].to_s, style, bold: true)
        when :sym
          build(args[0], style)
        when :frac
          child_style = frac_style(style)
          FracBox.new(
            self,
            build(args[0], child_style),
            build(args[1], child_style),
            style,
          )
        when :sqrt
          SqrtBox.new(self, build(args[0], style), style)
        when :sup
          ScriptBox.new(
            self, build(args[0], style),
            sup: build(args[1], script_style(style)), sub: nil,
            style_level: style,
          )
        when :sub
          ScriptBox.new(
            self, build(args[0], style),
            sup: nil, sub: build(args[1], script_style(style)),
            style_level: style,
          )
        when :subsup
          ScriptBox.new(
            self, build(args[0], style),
            sup: build(args[2], script_style(style)),
            sub: build(args[1], script_style(style)),
            style_level: style,
          )
        when :bigop
          build_bigop(args[0], args[1], args[2], style)
        when :space
          SpaceBox.new(args[0].to_f * size_for(style))
        when :display
          build(args[0], :display)
        when :inline
          build(args[0], :text)
        else
          raise ArgumentError, "unknown math tag: #{tag.inspect}"
        end
      end

      def build_row(items, style)
        RowBox.new(self, items.map { |item| build(item, style) }, style)
      end

      def build_bigop(op, under, over, style)
        glyph = Prawn::Math::BIGOP_GLYPHS[op]
        unless glyph
          raise ArgumentError, "unknown big operator: #{op.inspect}"
        end
        if style == :display
          BigOpBox.new(
            self, glyph,
            under: under && build(under, :script),
            over: over && build(over, :script),
            style_level: style,
          )
        else
          # Inline style: limits become side sub/superscripts.
          op_box = TextBox.new(self, glyph, style, atom: :op)
          if under || over
            script_style = script_style(style)
            ScriptBox.new(
              self, op_box,
              sup: over && build(over, script_style),
              sub: under && build(under, script_style),
              style_level: style,
            )
          else
            op_box
          end
        end
      end
    end
  end
end
