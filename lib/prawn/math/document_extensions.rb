# frozen_string_literal: true

module Prawn
  module Math
    # Document-level entry points for math typesetting.
    module DocumentExtensions
      # Lays out a math expression tree and returns the root box. The
      # box exposes +width+, +height+ (above baseline) and +depth+
      # (below baseline) so it can be embedded inline with ordinary
      # text on a shared baseline.
      #
      # @param expr [Object] expression tree (see Prawn::Math)
      # @param size [Number] base font size in points
      # @param display [Boolean] display vs. inline text style
      # @return [Prawn::Math::Box]
      def math_box(expr, size: 12, display: true)
        unless font_families.key?(Prawn::Math::FONT_FAMILY)
          Prawn::Math.install_fonts(self)
        end
        Prawn::Math.layout(self, expr, size: size, display: display)
      end

      # Lays out and renders a math expression tree. +at+ is the
      # [x, baseline] position of the formula's left edge in the
      # current user space. Returns the root box (with metrics) for
      # further positioning or debugging.
      #
      # @param expr [Object] expression tree (see Prawn::Math)
      # @param at [Array(Number, Number)] left edge and baseline
      # @param size [Number] base font size in points
      # @param display [Boolean] display vs. inline text style
      # @return [Prawn::Math::Box]
      def math(expr, at:, size: 12, display: true)
        box = math_box(expr, size: size, display: display)
        box.render(self, at[0], at[1])
        box
      end
    end
  end
end

Prawn::Document.include(Prawn::Math::DocumentExtensions)
