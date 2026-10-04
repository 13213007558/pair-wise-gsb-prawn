# frozen_string_literal: true

require_relative 'formula/box'
require_relative 'formula/renderer'

module Prawn
  # Small declarative mathematics typesetting for Prawn.
  #
  # This is intentionally not a TeX or LaTeX parser. Expressions are plain Ruby
  # arrays and hashes. The entry points are {Prawn::Document#math_layout} and
  # {Prawn::Document#draw_math}.
  module Formula
    DEFAULT_FONT_FAMILY = 'Prawn Math'

    DEFAULT_FONTS = {
      normal: "#{Prawn::DATADIR}/fonts/DejaVuSans.ttf",
      bold: "#{Prawn::DATADIR}/fonts/DejaVuSans-Bold.ttf",
    }.freeze

    # Symbolic large operators understood by the `:op` node.
    OPERATORS = {
      sum: '∑',
      product: '∏',
      integral: '∫',
    }.freeze

    # Declared symbol range covered without requiring users to install a font.
    # Additional glyphs are accepted only when they exist in the selected TTF or
    # OTF math font; missing glyphs raise {UnsupportedGlyph}.
    SUPPORTED_CHARACTERS =
      ([*(' '..'~'), *%w[∑ ∏ ∫ ± × ÷ ≠ ≤ ≥ ∞]]).freeze

    # Raised when a declarative expression cannot be built.
    InvalidExpression = Class.new(ArgumentError)

    # Raised when the configured math font lacks a requested glyph.
    UnsupportedGlyph = Class.new(StandardError)
  end

  class Document # rubocop:disable Style/Documentation
    # Measure a math expression without drawing it.
    #
    # The default font is the embedded DejaVu Sans regular/bold TTF family.
    # It supports printable ASCII, {SUPPORTED_CHARACTERS}, and the declared
    # operators in {OPERATORS}. Custom math fonts must be TTF or OTF files with
    # Unicode cmap tables. Every requested glyph is checked against the font;
    # missing glyphs raise {UnsupportedGlyph}. Fractions and radicals themselves
    # are stroked vector paths rather than glyphs.
    #
    # Supported expression nodes are:
    # - arrays: inline rows,
    # - strings: glyph runs,
    # - `{ text: value, style: :normal }`,
    # - `{ frac: [numerator, denominator] }`,
    # - `{ sqrt: expression }`,
    # - `{ sup: [base, script] }`,
    # - `{ sub: [base, script] }`,
    # - `{ script: { base:, upper:, lower: } }`,
    # - `{ op: :sum, upper:, lower: }`, and
    # - `{ space: width_in_em }`.
    #
    # Nodes may carry `id:` and `label:` metadata for boundary reports. Long
    # forms use `numerator:`/`denominator:`, `radicand:`, and `base:` with
    # `sup:`, `sub:`, or `upper:`/`lower:`.
    #
    # @param expression [Array, Hash, String, Numeric, Symbol]
    # @param options [Hash{Symbol => Object}]
    # @option options :size [Numeric] (font_size) root em size in points
    # @option options :font [String, Hash] registered family or TTF/OTF family
    # @return [Prawn::Formula::Box] measured root box
    def math_layout(expression, size: font_size, font: nil)
      build_math(expression, size, font)
    end

    # Return local and absolute boundary records for every box in a layout.
    #
    # @param layout [Prawn::Formula::Box]
    # @param at [Array(Numeric, Numeric)] baseline origin
    # @return [Array<Hash>]
    def math_layout_report(layout, at: [0, 0])
      layout.report(
        at[0] + bounds.absolute_left,
        at[1] + bounds.absolute_bottom,
      )
    end

    # Draw a measured math expression at a PDF text baseline.
    #
    # @param expression [Prawn::Formula::Box, Array, Hash, String, Numeric,
    #   Symbol]
    # @param at [Array(Numeric, Numeric)] baseline origin
    # @param size [Numeric] root em size in points
    # @param font [String, Hash, nil] registered family or TTF/OTF family
    # @param debug [Boolean] stroke every box and baseline
    # @return [Prawn::Formula::Box] measured root box
    def draw_math(expression, at:, size: font_size, font: nil, debug: false)
      layout =
        if expression.is_a?(Prawn::Formula::Box)
          expression
        else
          build_math(expression, size, font)
        end

      Prawn::Formula::Renderer.new(self, font: font).draw(
        layout,
        origin: at,
        debug: debug,
      )
      layout
    end

    private

    def build_math(expression, size, font)
      Prawn::Formula::Renderer.new(self, font: font).build(
        expression,
        size: size,
      )
    end
  end
end
