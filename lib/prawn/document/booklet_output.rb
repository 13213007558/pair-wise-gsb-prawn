# frozen_string_literal: true

module Prawn
  class Document
    # Renders a {Prawn::Booklet::Planner} plan into imposition sheets.
    module BookletOutput
      DEFAULT_OPTIONS = {
        pages_per_signature: 8,
        binding: :left,
        flip_edge: :short,
        paper_thickness: 0,
        creep_strategy: :inner,
        fit: :shrink,
        marks: true,
        mark_length: 18,
        mark_inset: 6,
        mark_gap: 9,
      }.freeze

      # Returns the booklet plan for the current document without rendering.
      #
      # @param options [Hash]
      # @return [Hash]
      def booklet_plan(**options)
        options = booklet_options(options)
        build_booklet_planner(options).to_h
      end

      # Replaces the document pages with double-sided booklet sheets.
      #
      # @param options [Hash]
      # @return [Hash] The plan used for rendering.
      def render_booklet(**options)
        options = booklet_options(options)
        planner = build_booklet_planner(options)

        unless @booklet_imposed
          (1..page_count).each do |number|
            go_to_page(number)
            repeaters.each { |repeater| repeater.run(number) }
          end
          renderer.finalize_all_page_contents

          source_pages = state.pages.dup
          source_page_ids = source_pages.map do |page|
            page.dictionary.identifier
          end
          source_background = @background
          @background = nil
          forms = source_pages.each_with_index.map do |page, index|
            crop_left, crop_bottom, crop_right, crop_top = page.crop_box
            [
              "BookletPage#{index + 1}",
              create_booklet_form(page),
              crop_left.to_f,
              crop_bottom.to_f,
              (crop_right - crop_left).to_f,
              (crop_top - crop_bottom).to_f,
            ]
          end

          panel_width, panel_height = booklet_panel_dimensions(source_pages)
          planner.sheets.each do |sheet|
            render_booklet_side(
              sheet.front, forms, panel_width, panel_height, options
            )
            render_booklet_side(
              sheet.back, forms, panel_width, panel_height, options
            )
          end

          remove_booklet_source_pages(source_pages.length)
          source_page_ids.each { |identifier| state.store[identifier].data.clear }
          @background = source_background
          @repeaters = []
          @page_number = planner.output_page_count
          state.page = state.pages.last
          @booklet_plan = planner.to_h
          @booklet_imposed = true
        end

        @booklet_plan || planner.to_h
      end

      private

      def booklet_options(options)
        DEFAULT_OPTIONS.merge(options.compact)
      end

      def build_booklet_planner(options)
        Booklet::Planner.new(
          page_count,
          pages_per_signature: options[:pages_per_signature],
          binding: options[:binding],
          flip_edge: options[:flip_edge],
          paper_thickness: options[:paper_thickness],
          creep_strategy: options[:creep_strategy],
        )
      end

      def booklet_panel_dimensions(source_pages)
        dimensions = source_pages.map do |page|
          crop_left, crop_bottom, crop_right, crop_top = page.crop_box
          [crop_right - crop_left, crop_top - crop_bottom]
        end

        [
          dimensions.map(&:first).max.to_f,
          dimensions.map(&:last).max.to_f,
        ]
      end

      def create_booklet_form(page)
        ref!(
          Type: :XObject,
          Subtype: :Form,
          BBox: page.crop_box,
          Resources: page.dictionary.data[:Resources],
        ).tap do |dictionary|
          dictionary.stream = page.content.stream
        end
      end

      def render_booklet_side(placements, forms, width, height, options)
        start_new_page(
          size: [width * 2, height],
          layout: :landscape,
          margin: 0,
        )
        forms.each do |name, form, *_dimensions|
          state.page.xobjects[name.to_sym] = form
        end

        canvas do
          placements.each do |placement|
            draw_booklet_placement(
              placement, forms, width, height, options
            )
          end
          draw_booklet_markers(width, height, options) if options[:marks]
        end
      end

      def draw_booklet_placement(placement, forms, width, height, options)
        source_number = placement.page.logical_number
        return if placement.page.blank

        panel_x = placement.panel.zero? ? 0 : width
        creep_x = placement.creep.fetch(:x).to_f
        form = forms.fetch(source_number - 1)
        crop_left = form[2]
        crop_bottom = form[3]
        source_width = form[4]
        source_height = form[5]
        scale = booklet_scale(source_width, source_height, width, height, options)
        rotation = placement.rotation
        scaled_width = source_width * scale
        scaled_height = source_height * scale
        x_center = panel_x + (width / 2.0) + creep_x
        y_center = height / 2.0

        cos = rotation == 180 ? -1 : 1
        a = cos * scale
        d = cos * scale
        x = x_center - (scaled_width / 2.0)
        y = y_center - (scaled_height / 2.0)
        if rotation == 180
          x += scaled_width
          y += scaled_height
        end
        e = x - a * crop_left
        f = y - d * crop_bottom

        add_booklet_clip(panel_x, 0, width, height)
        renderer.add_content(booklet_matrix(a, d, e, f))
        renderer.add_content("/#{form.first} Do")
        renderer.add_content('Q')
      end

      def booklet_scale(source_width, source_height, panel_width, panel_height, options)
        case options[:fit]
        when Numeric
          Float(options[:fit])
        when :none, nil
          1.0
        when :shrink, :fit
          [
            1.0,
            panel_width / source_width,
            panel_height / source_height,
          ].min
        else
          raise ArgumentError, 'fit must be :shrink, :fit, :none, or Numeric'
        end
      end

      def add_booklet_clip(x, y, width, height)
        renderer.add_content('q')
        renderer.add_content(
          PDF::Core.real_params([x, y, width, height]) + ' re W n'
        )
      end

      def booklet_matrix(a, d, e, f)
        "#{PDF::Core.real_params([a, 0, 0, d, e, f])} cm"
      end

      def draw_booklet_markers(width, height, options)
        length = Float(options[:mark_length])
        inset = Float(options[:mark_inset])
        gap = Float(options[:mark_gap])

        save_graphics_state
        line_width(0.5)
        draw_crop_markers(width, height, inset, length)
        draw_fold_markers(width, height, gap, length)
        restore_graphics_state
      end

      def draw_crop_markers(width, height, inset, length)
        right_edge = width * 2
        horizontal_edges = [inset, height - inset]

        horizontal_edges.each do |y|
          line([0, y], [length, y])
          line([right_edge, y], [right_edge - length, y])
        end

        [inset, right_edge - inset].each do |x|
          line([x, 0], [x, length])
          line([x, height], [x, height - length])
        end
      end

      def draw_fold_markers(width, height, gap, length)
        [gap, height - gap].each do |y|
          line([width - length, y], [width + length, y])
        end
      end

      def remove_booklet_source_pages(count)
        count.times { delete_page(0) }
      end
    end
  end
end
