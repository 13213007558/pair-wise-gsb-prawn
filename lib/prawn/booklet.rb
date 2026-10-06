# frozen_string_literal: true

module Prawn
  # Double-sided booklet imposition.
  module Booklet
    # Calculates signatures, sheet sides, page placement, and creep without
    # modifying the source document.
    class Planner
      BINDINGS = %i[left right].freeze
      FLIP_EDGES = %i[long short].freeze
      CREEP_STRATEGIES = %i[inner none].freeze

      Page = Struct.new(:logical_number, :blank, keyword_init: true) do
        def blank?
          blank
        end
      end
      Placement = Struct.new(
        :signature, :sheet, :side, :panel, :page, :rotation, :creep,
        keyword_init: true,
      )
      Sheet = Struct.new(:signature, :number, :front, :back, keyword_init: true)
      Signature = Struct.new(:number, :pages, :sheets, keyword_init: true)

      attr_reader :source_page_count, :logical_page_count,
        :pages_per_signature, :binding, :flip_edge, :paper_thickness,
        :creep_strategy

      def initialize(
        source_page_count,
        pages_per_signature: 8,
        binding: :left,
        flip_edge: :short,
        paper_thickness: 0,
        creep_strategy: :inner
      )
        @source_page_count = Integer(source_page_count)
        if @source_page_count <= 0
          raise ArgumentError, 'source_page_count must be positive'
        end

        @pages_per_signature = Integer(pages_per_signature)
        unless @pages_per_signature.positive? &&
            (@pages_per_signature % 4).zero?
          raise ArgumentError,
            'pages_per_signature must be a positive multiple of 4'
        end

        @binding = binding.to_sym
        unless BINDINGS.include?(@binding)
          raise ArgumentError, "binding must be one of #{BINDINGS.join(', ')}"
        end

        @flip_edge = flip_edge.to_sym
        unless FLIP_EDGES.include?(@flip_edge)
          raise ArgumentError, "flip_edge must be one of #{FLIP_EDGES.join(', ')}"
        end

        @paper_thickness = Float(paper_thickness)
        if @paper_thickness.negative?
          raise ArgumentError, 'paper_thickness cannot be negative'
        end

        @creep_strategy = creep_strategy.to_sym
        unless CREEP_STRATEGIES.include?(@creep_strategy)
          raise ArgumentError,
            "creep_strategy must be one of #{CREEP_STRATEGIES.join(', ')}"
        end

        @logical_page_count = signature_count * @pages_per_signature
      end

      def blank_page_count
        logical_page_count - source_page_count
      end

      def signature_count
        @signature_count ||=
          (source_page_count.to_f / pages_per_signature).ceil
      end

      def sheets_per_signature
        pages_per_signature / 4
      end

      def sheet_count
        signature_count * sheets_per_signature
      end

      def output_page_count
        sheet_count * 2
      end

      def pages
        @pages ||= Array.new(logical_page_count) do |index|
          number = index + 1
          Page.new(
            logical_number: number,
            blank: number > source_page_count,
          )
        end
      end

      def signatures
        @signatures ||= Array.new(signature_count) do |signature_index|
          start = signature_index * pages_per_signature
          numbers = (1..pages_per_signature).map { |offset| start + offset }

          Signature.new(
            number: signature_index + 1,
            pages: numbers.map { |number| pages.fetch(number - 1) },
            sheets: build_sheets(signature_index + 1, numbers.dup),
          )
        end
      end

      def sheets
        @sheets ||= signatures.flat_map(&:sheets)
      end

      def placements
        @placements ||= sheets.flat_map do |sheet|
          [sheet.front, sheet.back].flatten
        end
      end

      def to_h
        {
          source_page_count: source_page_count,
          logical_page_count: logical_page_count,
          blank_page_count: blank_page_count,
          pages_per_signature: pages_per_signature,
          signature_count: signature_count,
          sheet_count: sheet_count,
          output_page_count: output_page_count,
          binding: binding,
          flip_edge: flip_edge,
          paper_thickness: paper_thickness,
          creep_strategy: creep_strategy,
          pages: pages.map { |page| page_to_h(page) },
          signatures: signatures.map { |signature| signature_to_h(signature) },
          sheets: sheets.map { |sheet| sheet_to_h(sheet) },
          placements: placements.map { |placement| placement_to_h(placement) },
        }
      end

      private

      def build_sheets(signature_number, numbers)
        Array.new(sheets_per_signature) do |sheet_index|
          sheet_number =
            (signature_number - 1) * sheets_per_signature + sheet_index + 1
          outer_low = numbers.first
          inner_low = numbers[1]
          inner_high = numbers[-2]
          outer_high = numbers.last
          front_numbers =
            if binding == :left
              [outer_high, outer_low]
            else
              [outer_low, outer_high]
            end
          back_numbers =
            if binding == :left
              [inner_low, inner_high]
            else
              [inner_high, inner_low]
            end
          numbers = numbers[1...-1]
          numbers.shift
          numbers.pop
          creep = creep_amount(sheet_index)

          Sheet.new(
            signature: signature_number,
            number: sheet_number,
            front: build_side(
              signature_number, sheet_number, :front, front_numbers, creep
            ),
            back: build_side(
              signature_number, sheet_number, :back, back_numbers, creep
            ),
          )
        end
      end

      def build_side(signature_number, sheet_number, side, numbers, creep)
        placements = numbers.each_with_index.map do |number, panel|
          build_placement(
            signature_number, sheet_number, side, panel, number, creep
          )
        end

        placements
      end

      def build_placement(signature_number, sheet_number, side, panel, number, creep)
        creep_direction = panel.zero? ? 1 : -1
        creep_direction = -creep_direction if side == :back

        Placement.new(
          signature: signature_number,
          sheet: sheet_number,
          side: side,
          panel: panel,
          page: pages.fetch(number - 1),
          rotation: side == :back && flip_edge == :long ? 180 : 0,
          creep: { x: creep_direction * creep, y: 0 },
        )
      end

      def creep_amount(sheet_index)
        return 0 if creep_strategy == :none || paper_thickness.zero?

        inner_sheet = sheets_per_signature - 1 - sheet_index
        inner_sheet * paper_thickness / 2.0
      end

      def signature_to_h(signature)
        {
          number: signature.number,
          pages: signature.pages.map { |page| page_to_h(page) },
          sheet_numbers: signature.sheets.map(&:number),
        }
      end

      def sheet_to_h(sheet)
        {
          signature: sheet.signature,
          number: sheet.number,
          front: sheet.front.map { |placement| placement_to_h(placement) },
          back: sheet.back.map { |placement| placement_to_h(placement) },
        }
      end

      def placement_to_h(placement)
        {
          signature: placement.signature,
          sheet: placement.sheet,
          side: placement.side,
          panel: placement.panel,
          logical_page: placement.page.logical_number,
          blank: placement.page.blank,
          rotation: placement.rotation,
          creep: placement.creep,
        }
      end

      def page_to_h(page)
        { logical_page: page.logical_number, blank: page.blank }
      end
    end
  end
end
