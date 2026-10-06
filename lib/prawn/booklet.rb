# frozen_string_literal: true

module Prawn
  class Document
    # Imposition support for printing existing Prawn pages as folded booklets.
    module Booklet
      Placement = Struct.new(
        :source_page, :side, :position, :rotation, :creep,
        keyword_init: true,
      ) do
        def blank?
          source_page.nil?
        end
      end
      Side = Struct.new(:number, :placements, keyword_init: true)
      Sheet = Struct.new(:number, :front, :back, keyword_init: true)

      class Plan
        attr_reader :page_count, :pages_per_signature, :binding, :flip,
          :paper_thickness, :scale, :marks, :mark_margin

        def initialize(page_count:, pages_per_signature:, binding:, flip:,
          paper_thickness:, scale:, marks:, mark_margin: 18)
          @page_count = page_count
          @pages_per_signature = pages_per_signature
          @binding = binding
          @flip = flip
          @paper_thickness = paper_thickness
          @scale = scale
          @marks = marks
          @mark_margin = mark_margin

          validate!
        end

        def blank_page_count
          rounded_page_count - page_count
        end

        def padded_page_count
          rounded_page_count
        end

        def signature_count
          padded_page_count / pages_per_signature
        end

        def sheets
          @sheets ||= build_sheets
        end

        def signatures
          sheets.group_by(&:number).values
        end

        private

        def validate!
          unless page_count.is_a?(Integer) && page_count >= 0
            raise ArgumentError, 'page_count must be a non-negative Integer'
          end

          unless pages_per_signature.is_a?(Integer) &&
            pages_per_signature.positive? &&
            pages_per_signature % 4 == 0
            raise ArgumentError,
              'pages_per_signature must be a positive multiple of 4'
          end

          unless %i[left right].include?(binding)
            raise ArgumentError, 'binding must be :left or :right'
          end

          unless %i[short long].include?(flip)
            raise ArgumentError, 'flip must be :short or :long'
          end

          unless paper_thickness.is_a?(Numeric) && paper_thickness >= 0
            raise ArgumentError, 'paper_thickness must be non-negative'
          end

          unless scale.nil? || scale == :fit ||
            (scale.is_a?(Numeric) && scale.positive?)
            raise ArgumentError, 'scale must be :fit or a positive number'
          end

          unless mark_margin.is_a?(Numeric) && mark_margin >= 0
            raise ArgumentError, 'mark_margin must be non-negative'
          end
        end

        def rounded_page_count
          @rounded_page_count ||=
            (page_count.to_f / pages_per_signature).ceil * pages_per_signature
        end

        def build_sheets
          signatures =
            (1..padded_page_count).each_slice(pages_per_signature).to_a

          signatures.each_with_index.flat_map do |signature, index|
            build_signature(signature, index)
          end
        end

        def build_signature(pages, signature_index)
          sheets_per_signature = pages.length / 4

          (0...sheets_per_signature).map do |sheet_index|
            outer = sheet_index * 2
            inner = pages.length - 1 - outer
            front_numbers = ordered_numbers(pages[inner], pages[outer])
            back_numbers = ordered_numbers(pages[outer + 1], pages[inner - 1])
            global_sheet = signature_index * sheets_per_signature + sheet_index

            Sheet.new(
              number: signature_index + 1,
              front: Side.new(
                number: global_sheet * 2 + 1,
                placements: side_placements(front_numbers, :front, sheet_index,
                  sheets_per_signature),
              ),
              back: Side.new(
                number: global_sheet * 2 + 2,
                placements: side_placements(back_numbers, :back, sheet_index,
                  sheets_per_signature),
              ),
            )
          end
        end

        def ordered_numbers(left_page, right_page)
          case binding
          when :left then [left_page, right_page]
          when :right then [right_page, left_page]
          end
        end

        def side_placements(numbers, side, sheet_index, sheets_per_signature)
          numbers.each_with_index.map do |number, index|
            creep = paper_thickness *
              (sheets_per_signature - 1 - sheet_index) / 2.0

            Placement.new(
              source_page: number <= page_count ? number : nil,
              side: side,
              position: index.zero? ? :left : :right,
              rotation: side == :back && flip == :long ? 180 : 0,
              creep: creep * creep_direction(index),
            )
          end
        end

        def creep_direction(index)
          index.zero? ? -1 : 1
        end
      end

      # Builds an imposition plan without rendering.
      def booklet_plan(pages_per_signature: 16, binding: :left, flip: :short,
        paper_thickness: 0, scale: :fit, marks: true, mark_margin: 18)
        Plan.new(
          page_count: page_count,
          pages_per_signature: pages_per_signature,
          binding: binding,
          flip: flip,
          paper_thickness: paper_thickness,
          scale: scale,
          marks: marks,
          mark_margin: mark_margin,
        )
      end

      # Renders existing pages after yielding the imposition plan.
      def render_booklet(output = nil, pages_per_signature: 16, binding: :left,
        flip: :short, paper_thickness: 0, scale: :fit, marks: true,
        mark_margin: 18, &block)
        plan = booklet_plan(
          pages_per_signature: pages_per_signature,
          binding: binding,
          flip: flip,
          paper_thickness: paper_thickness,
          scale: scale,
          marks: marks,
          mark_margin: mark_margin,
        )
        block&.call(plan)

        Imposer.new(self, plan).render(output)
      end
      

      class Imposer
        def initialize(document, plan)
          @document = document
          @plan = plan
        end

        def render(output)
          run_source_repeaters
          source_dimensions = collect_source_dimensions
          forms = create_forms
          source_object_ids = replace_pages
          impose(forms, source_dimensions)
          retire_source_objects(source_object_ids)
          @document.renderer.render(output)
        end

        private

        def run_source_repeaters
          (1..@document.page_count).each do |number|
            @document.go_to_page(number)
            @document.repeaters.each { |repeater| repeater.run(number) }
          end
        end

        def collect_source_dimensions
          @document.state.pages.map do |page|
            crop = page.dictionary.data[:CropBox] || page.crop_box
            { crop: crop.map(&:to_f) }
          end
        end

        def create_forms
          @document.renderer.finalize_all_page_contents

          @document.state.pages.each_with_object({}) do |page, forms|
            form_ref = content_reference(page)
            form_ref.identifier = next_object_identifier
            crop = crop_box(page)
            form_ref.data = form_ref.data.merge(
              Type: :XObject,
              Subtype: :Form,
              BBox: [0, 0, crop[2] - crop[0], crop[3] - crop[1]],
              Resources: page.dictionary.data[:Resources],
            )
            add_crop_translation(form_ref, page, crop)
            @document.state.store.push(form_ref)
            forms[forms.length + 1] = form_ref
          end
        end

        def content_reference(page)
          contents = Array(page.dictionary.data[:Contents])
          form_data = {
            Type: :XObject,
            Subtype: :Form,
            BBox: crop_box(page),
            Resources: page.dictionary.data[:Resources],
          }
          if contents.one?
            @document.state.store[contents.first.identifier].deep_copy
          else
            reference = PDF::Core::Reference.new(0, form_data)
            contents.each do |content|
              stream = @document.state.store[content.identifier].stream
              reference << stream.filtered_stream
            end
            reference
          end
        end

        def add_crop_translation(form_ref, page, crop)
          form_ref.stream = PDF::Core::Stream.new
          transform = PDF::Core.real_params([1, 0, 0, 1, -crop[0], -crop[1]])
          form_ref << 'q ' << transform << " cm\n"
          Array(page.dictionary.data[:Contents]).each do |content|
            stream = @document.state.store[content.identifier].stream
            form_ref << stream.filtered_stream
          end
          form_ref << 'Q'
        end

        def crop_box(page)
          (page.dictionary.data[:CropBox] || page.crop_box).map(&:to_f)
        end

        def replace_pages
          pages = @document.state.pages.dup
          source_object_ids = pages.flat_map do |page|
            [page.dictionary.identifier] +
              Array(page.dictionary.data[:Contents]).map(&:identifier)
          end.uniq

          @document.state.pages.clear
          @document.state.page = nil
          @document.instance_variable_set(:@page_number, 0)
          @document.state.store.pages.data[:Kids].clear
          @document.state.store.pages.data[:Count] = 0

          source_object_ids
        end

        def retire_source_objects(identifiers)
          identifiers.each do |identifier|
            reference = @document.state.store[identifier]
            reference.data = nil
            reference.stream = PDF::Core::Stream.new
          end
        end

        def next_object_identifier
          identifiers =
            @document.state.store.instance_variable_get(:@identifiers)
          identifiers.max.to_i + 1
        end

        def impose(forms, source_dimensions)
          reference = source_dimensions.first ||
            { crop: [0.0, 0.0, 0.0, 0.0] }
          sheet_size = output_size(reference)

          @plan.sheets.each do |sheet|
            [sheet.front, sheet.back].each do |side|
              @document.start_new_page(
                size: sheet_size,
                layout: :portrait,
                margin: 0,
              )
              side.placements.each do |placement|
                place(
                  placement, forms, reference, source_dimensions, sheet_size,
                )
              end
              draw_marks(sheet_size) if @plan.marks
            end
          end
        end

        def output_size(reference)
          source_width = reference[:crop][2] - reference[:crop][0]
          source_height = reference[:crop][3] - reference[:crop][1]
          margin = @plan.marks ? @plan.mark_margin : 0
          [source_width * 2 + margin * 2, source_height + margin * 2]
        end

        def place(placement, forms, reference, source_dimensions, sheet_size)
          source =
            placement.source_page &&
              source_dimensions[placement.source_page - 1]
          return unless source

          form = forms[placement.source_page]
          form_name = "BP#{placement.source_page}"
          @document.state.page.xobjects[form_name] = form

          source_crop = source[:crop]
          source_width = source_crop[2] - source_crop[0]
          source_height = source_crop[3] - source_crop[1]
          reference_width = reference[:crop][2] - reference[:crop][0]
          reference_height = reference[:crop][3] - reference[:crop][1]
          factor = scale_factor(source_width, source_height,
            reference_width, reference_height)
          margin = @plan.marks ? @plan.mark_margin : 0
          panel_x = placement.position == :left ? margin : sheet_size[0] / 2.0
          target_x = panel_x + (reference_width - source_width * factor) / 2.0
          target_y = margin + (reference_height - source_height * factor) / 2.0
          target_x += placement.creep
          clip = [
            target_x, target_y, source_width * factor, source_height * factor,
          ]

          if placement.rotation.zero?
            matrix = [
              factor, 0, 0, factor,
              target_x,
              target_y,
            ]
          else
            matrix = [
              -factor, 0, 0, -factor,
              target_x + source_width * factor,
              target_y + source_height * factor,
            ]
          end

          params = PDF::Core.real_params(matrix)
          rectangle = PDF::Core.real_params(clip)
          @document.renderer.add_content(
            "q\n#{rectangle} re W n\n#{params} cm\n/#{form_name} Do\nQ",
          )
        end

        def scale_factor(source_width, source_height, reference_width,
          reference_height)
          case @plan.scale
          when :fit
            factors = [
              reference_width / source_width,
              reference_height / source_height,
            ]
            factors.min
          else
            @plan.scale
          end
        end

        def draw_marks(sheet_size)
          margin = @plan.mark_margin
          width, height = sheet_size
          mark_length = [9, margin * 0.6].min
          coordinates = [
            [margin, margin, -1, -1],
            [width - margin, margin, 1, -1],
            [margin, height - margin, -1, 1],
            [width - margin, height - margin, 1, 1],
          ]

          instructions = +"
            q
            0.5 w
            [4 3] 0 d
            #{PDF::Core.real_params([width / 2.0, margin])} m
            #{PDF::Core.real_params([width / 2.0, height - margin])} l S
            Q
            q
            0.5 w
          "

          coordinates.each do |x, y, direction_x, direction_y|
            horizontal_end = x + direction_x * mark_length
            vertical_end = y + direction_y * mark_length
            instructions << PDF::Core.real_params([x, y]) << " m "
            horizontal = PDF::Core.real_params([horizontal_end, y])
            instructions << horizontal << " l S "
            instructions << PDF::Core.real_params([x, y]) << " m "
            instructions << PDF::Core.real_params([x, vertical_end]) << " l S "
          end

          instructions << "Q\n"
          @document.renderer.add_content(instructions)
        end
      end
    end
  end
end
