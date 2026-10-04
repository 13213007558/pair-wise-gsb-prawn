# frozen_string_literal: true

require_relative 'document'

module Prawn
  # Prawn::Math is a small, declarative math typesetter for Prawn.
  #
  # It turns a plain Ruby expression tree into a set of positioned boxes
  # (width / height / depth, like TeX) that can be rendered on a baseline
  # anywhere in a document, including inline with ordinary text.
  #
  # == Supported scope (explicit, by design)
  #
  # This is *not* a LaTeX parser. Expressions are built from Ruby data:
  #
  #   "x"                          # upright text atom
  #   :alpha                       # named symbol (see SYMBOLS)
  #   [:t, "sin"]                # text atom (optional :bold as 3rd item)
  #   [:b, "E"]                  # bold text atom
  #   [:row, a, b, ...]            # horizontal composition (bare arrays too)
  #   [:frac, num, den]            # fraction with a rule
  #   [:sqrt, radicand]            # radical drawn with vector lines
  #   [:sup, base, sup]            # superscript
  #   [:sub, base, sub]            # subscript
  #   [:subsup, base, sub, sup]    # both scripts
  #   [:bigop, :sum, under, over]  # large operator with limits
  #   [:space, 0.5]                # explicit space, in em of current style
  #   [:display, expr]             # force display style
  #   [:inline, expr]              # force text (inline) style
  #
  # Fonts: DejaVu Sans (regular + bold), registered under the
  # +PrawnMath+ family via {Prawn::Math.install_fonts}. Italic faces are
  # intentionally out of scope; variables are set upright.
  #
  # Symbols: the named symbols in {Prawn::Math::SYMBOLS} (Greek letters,
  # common operators and relations) plus the large operators in
  # {Prawn::Math::BIGOP_GLYPHS} (sum, product, integral). All glyphs are
  # covered by DejaVu Sans. The radical sign is *drawn* as vector lines
  # so it always covers the full radicand at any nesting depth.
  module Math
    # Font family name the math typesetter registers and uses.
    FONT_FAMILY = 'PrawnMath'

    # Font files (relative to a font directory) used for the family.
    FONT_FILES = {
      normal: 'DejaVuSans.ttf',
      bold: 'DejaVuSans-Bold.ttf',
    }.freeze

    # Named symbols supported by the typesetter. All glyphs are present
    # in DejaVu Sans.
    SYMBOLS = {
      # Greek, lowercase
      alpha: "\u03B1", beta: "\u03B2", gamma: "\u03B3",
      delta: "\u03B4", epsilon: "\u03B5", zeta: "\u03B6",
      eta: "\u03B7", theta: "\u03B8", iota: "\u03B9",
      kappa: "\u03BA", lambda: "\u03BB", mu: "\u03BC",
      nu: "\u03BD", xi: "\u03BE", pi: "\u03C0", rho: "\u03C1",
      sigma: "\u03C3", tau: "\u03C4", upsilon: "\u03C5",
      phi: "\u03C6", chi: "\u03C7", psi: "\u03C8", omega: "\u03C9",
      # Greek, uppercase
      Gamma: "\u0393", Delta: "\u0394", Theta: "\u0398",
      Lambda: "\u039B", Xi: "\u039E", Pi: "\u03A0",
      Sigma: "\u03A3", Phi: "\u03A6", Psi: "\u03A8",
      Omega: "\u03A9",
      # Operators and relations
      pm: "\u00B1", mp: "\u2213", times: "\u00D7", div: "\u00F7",
      cdot: "\u00B7", minus: "\u2212", ast: "\u2217",
      leq: "\u2264", geq: "\u2265", neq: "\u2260",
      approx: "\u2248", equiv: "\u2261", sim: "\u223C",
      in: "\u2208", notin: "\u2209", subset: "\u2282",
      subseteq: "\u2286", supset: "\u2283", supseteq: "\u2287",
      cup: "\u222A", cap: "\u2229", land: "\u2227", lor: "\u2228",
      lnot: "\u00AC", forall: "\u2200", exists: "\u2203",
      partial: "\u2202", nabla: "\u2207", infty: "\u221E",
      propto: "\u221D", emptyset: "\u2205",
      to: "\u2192", mapsto: "\u21A6", implies: "\u21D2",
      iff: "\u21D4", ldots: "\u2026", cdots: "\u22EF",
      prime: "\u2032", deg: "\u00B0", perp: "\u22A5",
      parallel: "\u2225", angle: "\u2220", therefore: "\u2234",
      because: "\u2235",
    }.freeze

    # Large operators supported by [:bigop, name, under, over].
    BIGOP_GLYPHS = {
      sum: "\u2211",
      prod: "\u220F",
      int: "\u222B",
    }.freeze

    # Single characters treated as relations for inter-atom spacing.
    RELATION_CHARS = %w[= < > \u2264 \u2265 \u2260 \u2248 \u2261 \u223C
                        \u2208 \u2209 \u2282 \u2286 \u2283 \u2287 \u221D
                        \u2192 \u21A6 \u21D2 \u21D4 \u22A5 \u2225].freeze

    # Single characters treated as binary operators for spacing.
    BINARY_CHARS = %w[+ \u2212 \u00B1 \u2213 \u00D7 \u00F7 \u00B7 \u2217
                      \u222A \u2229 \u2227 \u2228].freeze

    # Font-size scale per math style level.
    STYLE_SCALE = { display: 1.0, text: 1.0, script: 0.7, scriptscript: 0.5 }.freeze

    # Registers the math font family on a document.
    #
    # @param pdf [Prawn::Document]
    # @param font_dir [String] directory containing DejaVuSans.ttf and
    #   DejaVuSans-Bold.ttf (defaults to Prawn's bundled data/fonts).
    # @return [String] the registered family name
    def self.install_fonts(pdf, font_dir: File.join(Prawn::DATADIR, 'fonts'))
      pdf.font_families.update(
        FONT_FAMILY => {
          normal: File.join(font_dir, FONT_FILES[:normal]),
          bold: File.join(font_dir, FONT_FILES[:bold]),
        },
      )
      FONT_FAMILY
    end

    # Lays out an expression tree.
    #
    # @param pdf [Prawn::Document] used for font metrics
    # @param expr [Object] the expression tree (see module docs)
    # @param size [Number] base font size in points
    # @param display [Boolean] display style (limits above/below big
    #   operators, roomier fractions) vs. inline text style
    # @return [Prawn::Math::Box] root box with width/height/depth
    def self.layout(pdf, expr, size: 12, display: true)
      Layout.new(pdf, size).build(expr, display ? :display : :text)
    end
  end
end

require_relative 'math/layout'
require_relative 'math/box'
require_relative 'math/boxes'
require_relative 'math/document_extensions'
