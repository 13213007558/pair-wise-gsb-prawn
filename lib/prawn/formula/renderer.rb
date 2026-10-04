# frozen_string_literal: true

module Prawn
  module Formula
    # Builds and draws declarative math expression boxes.
    class Renderer
      SCRIPT_SCALE = 0.7
      FRACTION_SCALE = 0.82
      OPERATOR_SCALE = 1.2

      def initialize(document, font: nil)
        @document = document
        @family = configure_font(font)
        @fonts = {}
        @next_id = 0
        font_for(:normal)
      end

      def build(expression, size: nil)
        size ||= document.font_size
        box = build_node(normalize(expression), size.to_f, nil)
        box.font_family = family
        box
      end

      def draw(box, origin:, debug: false)
        document.save_graphics_state do
          document.font(box.font_family || family) do
            draw_box(box, origin[0].to_f, origin[1].to_f)
            stroke_debug(box, origin[0].to_f, origin[1].to_f) if debug
          end
        end
      end

      private

      attr_reader :document, :family

      def configure_font(font)
        case font
        when nil
          unless document.font_families.key?(DEFAULT_FONT_FAMILY)
            document.font_families[DEFAULT_FONT_FAMILY] = DEFAULT_FONTS
          end
          DEFAULT_FONT_FAMILY
        when String, Symbol
          name = font.to_s
          if name == DEFAULT_FONT_FAMILY &&
              !document.font_families.key?(name)
            document.font_families[name] = DEFAULT_FONTS
          end
          name
        when Hash
          configure_font_hash(font)
        else
          raise ArgumentError, 'math :font must be a family name or hash'
        end
      end

      def configure_font_hash(font)
        name = font[:family] || font['family']
        unless name
          raise ArgumentError, 'math font hash must include :family'
        end

        definition = font.reject { |key| key.to_sym == :family }
        document.font_families[name] = definition unless definition.empty?
        name
      end

      def normalize(expression)
        case expression
        when Array
          expression.map { |item| normalize(item) }
        when String, Numeric, Symbol
          if expression.is_a?(Symbol) && OPERATORS.key?(expression)
            { type: :op, name: expression, upper: [], lower: [] }
          else
            expression
          end
        when Hash
          normalize_hash(expression)
        else
          invalid_expression(expression)
        end
      end

      def normalize_hash(hash)
        type = node_type(hash)
        normalized = {
          type: type,
          id: hash[:id],
          label: hash[:label],
        }

        case type
        when :text
          normalized[:value] = String(hash[:text])
          normalized[:style] = hash.fetch(:style, :normal).to_sym
        when :space
          normalized[:width] = Float(hash.fetch(:space))
        when :frac
          if hash.key?(:frac) && hash[:frac].is_a?(Array)
            normalized[:numerator] = normalize(hash[:frac][0])
            normalized[:denominator] = normalize(hash[:frac][1])
          else
            normalized[:numerator] = normalize(hash.fetch(:numerator))
            normalized[:denominator] = normalize(hash.fetch(:denominator))
          end
        when :sqrt
          normalized[:radicand] =
            normalize(hash.key?(:radicand) ? hash[:radicand] : hash[:sqrt])
        when :sup, :sub
          if hash.key?(:base)
            normalized[:base] = normalize(hash.fetch(:base))
            script =
              if hash.key?(type)
                value = hash[type]
                value.is_a?(Array) ? value[0] : value
              else
                hash.fetch(:script)
              end
            normalized[:script] = normalize(script)
          else
            pair = hash.fetch(type)
            normalized[:base] = normalize(pair[0])
            normalized[:script] = normalize(pair[1])
          end
        when :script
          normalized[:base] = normalize(hash.fetch(:base))
          normalized[:upper] =
            hash.key?(:upper) ? normalize(hash[:upper]) : []
          normalized[:lower] =
            hash.key?(:lower) ? normalize(hash[:lower]) : []
        when :op
          name = hash.fetch(:op).to_sym
          unless OPERATORS.key?(name)
            raise InvalidExpression,
              "unknown math operator #{name.inspect}"
          end
          normalized[:name] = name
          normalized[:upper] = normalize(hash.fetch(:upper, []))
          normalized[:lower] = normalize(hash.fetch(:lower, []))
        end

        normalized
      end

      def node_type(hash)
        return :frac if hash.key?(:numerator) && hash.key?(:denominator)
        return :sqrt if hash.key?(:radicand)
        return :sup if hash.key?(:base) && hash.key?(:sup)
        return :sub if hash.key?(:base) && hash.key?(:sub)
        return :script if hash.key?(:base) &&
          (hash.key?(:upper) || hash.key?(:lower))

        shorthand =
          %i[text space frac sqrt sup sub op].find do |key|
          hash.key?(key)
        end
        return shorthand if shorthand

        raise InvalidExpression,
          "unknown math expression #{hash.inspect}"
      end

      def invalid_expression(expression)
        raise InvalidExpression,
          "unsupported math expression #{expression.inspect}"
      end

      def build_node(node, size, parent_type)
        case node
        when Array then build_row(node, size)
        when String, Numeric then build_text(String(node), :normal, size)
        when Hash then build_hash_node(node, size, parent_type)
        else invalid_expression(node)
        end
      end

      def build_hash_node(node, size, parent_type)
        case node[:type]
        when :text
          build_text(node[:value], node[:style], size, node)
        when :space
          build_space(node, size)
        when :frac
          build_fraction(node, size)
        when :sqrt
          build_sqrt(node, size)
        when :sup, :sub
          build_script_pair(node, size)
        when :script
          build_scripts(node, size)
        when :op
          build_operator_node(
            node[:name], node[:upper], node[:lower], size, node
          )
        else
          invalid_expression(node)
        end
      end

      def build_row(nodes, size)
        box = create_box(:row, nil, nodes)
        children = nodes.map { |node| build_node(node, size, :row) }
        cursor = 0.0
        children.each do |child|
          box.add_child(child, cursor, 0.0)
          cursor += child.width
        end
        size_box_to_children(box, children)
        box
      end

      def build_text(value, style, size, source = nil)
        if value.empty?
          raise InvalidExpression, 'math text cannot be empty'
        end

        font = font_for(style)
        verify_glyphs(font, value)
        metrics = text_metrics(font, value, size)
        box = Box.new(
          type: source&.dig(:type) == :op ? :op_glyph : :text,
          width: metrics[:width],
          height: metrics[:height],
          depth: metrics[:depth],
        )
        identify(box, source)
        box.details.update(
          text: value,
          style: style,
          size: size,
          font: family,
        )
        box.drawing = { kind: :text, value: value, style: style, size: size }
        box
      end

      def build_space(node, size)
        width = node[:width] * size
        box = Box.new(type: :space, width: width, height: 0, depth: 0)
        identify(box, node)
        box.details.update(advance: width, size: size)
        box
      end

      def font_for(style)
        @fonts[style] ||= begin
          font = document.find_font(family, style: style)
          unless font.is_a?(Prawn::Fonts::TTF)
            raise ArgumentError,
              'math fonts must be TTF or OTF fonts with Unicode cmap tables'
          end
          font
        end
      end

      def verify_glyphs(font, value)
        value.each_grapheme_cluster do |grapheme|
          next if grapheme.strip.empty?
          unless font.respond_to?(:glyph_present?) &&
              font.glyph_present?(grapheme)
            raise UnsupportedGlyph,
              "math font #{family.inspect} lacks #{grapheme.inspect}"
          end
        end
      end

      def text_metrics(font, value, size)
        width = font.compute_width_of(value, size: size)
        bounds = glyph_bounds(font, value, size)
        if bounds
          {
            width: width,
            height: bounds[:height],
            depth: bounds[:depth],
          }
        else
          raise UnsupportedGlyph,
            'math requires glyph outline metrics from a TTF or OTF font'
        end
      end

      def glyph_bounds(font, value, size)
        return nil unless font.is_a?(Prawn::Fonts::TTF)

        ttf = font.instance_variable_get(:@ttf)
        cmap = ttf.cmap.unicode.first
        scale_factor = font.send(:scale_factor) * size / 1000.0
        min_x = min_y = nil
        max_x = max_y = nil

        value.codepoints.each do |code|
          glyph = ttf.glyph_outlines.for(cmap[code])
          next unless glyph

          min_x = [min_x, glyph.x_min * scale_factor].compact.min
          max_x = [max_x, glyph.x_max * scale_factor].compact.max
          min_y = [min_y, glyph.y_min * scale_factor].compact.min
          max_y = [max_y, glyph.y_max * scale_factor].compact.max
        end

        return nil if min_x.nil?

        { height: max_y, depth: -min_y, left: min_x, right: max_x }
      end

      def create_box(type, children, source = nil)
        box = Box.new(type: type, width: 0, height: 0, depth: 0)
        identify(box, source.is_a?(Hash) ? source : nil)
        box
      end

      def identify(box, source)
        source_id = source.is_a?(Hash) ? source[:id] : nil
        box.id = source_id || format('M%02d', next_id)
        box.label = source&.dig(:label) || box.type.to_s
      end

      def next_id
        @next_id += 1
      end

      def size_box_to_children(box, children)
        box.width = children.sum(&:width)
        box.height = children.map { |child| child.y + child.height }.max || 0
        box.depth =
          children.map { |child| child.depth - child.y }.max || 0
      end

      def build_fraction(node, size)
        child_size = size * FRACTION_SCALE
        numerator = build_node(node[:numerator], child_size, :frac)
        denominator = build_node(node[:denominator], child_size, :frac)
        gap = 0.12 * size
        thickness = [0.045 * size, 0.6].max
        bar_y = 0.25 * size
        width = [numerator.width, denominator.width].max
        numerator_y =
          bar_y + thickness / 2.0 + gap + numerator.depth
        denominator_y =
          bar_y - thickness / 2.0 - gap - denominator.height

        box = Box.new(
          type: :fraction,
          width: width,
          height: numerator_y + numerator.height,
          depth: denominator.depth - denominator_y,
        )
        identify(box, node)
        box.add_child(
          numerator,
          (width - numerator.width) / 2.0,
          numerator_y,
        )
        box.add_child(
          denominator,
          (width - denominator.width) / 2.0,
          denominator_y,
        )
        box.details.update(
          axis_y: bar_y,
          bar_thickness: thickness,
          bar_left: 0,
          bar_right: width,
        )
        box.drawing = { kind: :fraction, y: bar_y, thickness: thickness }
        box
      end

      def build_sqrt(node, size)
        radicand = build_node(node[:radicand], size, :sqrt)
        line = [0.045 * size, 0.6].max
        left = 0.12 * size
        notch_x = left + 0.48 * size
        right_pad = 0.1 * size
        foot_x = left + 0.16 * size
        notch_y = 0.12 * size
        foot_y = -(radicand.depth + 0.08 * size)
        tip_y = [
          radicand.height + 0.22 * size + line,
          notch_y + 0.45 * size + line,
        ].max
        bar_y = tip_y - line / 2.0
        width = notch_x + radicand.width + right_pad

        box = Box.new(
          type: :sqrt,
          width: width,
          height: tip_y + line / 2.0,
          depth: [radicand.depth + 0.08 * size, -foot_y].max,
        )
        identify(box, node)
        box.add_child(radicand, notch_x, 0.0)
        box.details.update(
          radical_left_x: left,
          radical_foot: [foot_x, foot_y],
          radical_notch: [notch_x, notch_y],
          radical_tip: [left, tip_y],
          overbar_y: bar_y,
          overbar_left: notch_x,
          overbar_right: width - right_pad / 2.0,
          overbar_thickness: line,
        )
        box.drawing = {
          kind: :sqrt,
          line: line,
          points: [
            [left, tip_y],
            [notch_x, notch_y],
            [foot_x, foot_y],
          ],
          overbar: [notch_x, bar_y, width - right_pad / 2.0],
        }
        box
      end

      def build_script_pair(node, size)
        scripts = {
          upper: node[:type] == :sup ? node[:script] : [],
          lower: node[:type] == :sub ? node[:script] : [],
        }
        source = node.merge(type: :script)
        build_scripts(
          source.merge(scripts),
          size,
          type: node[:type],
        )
      end

      def build_scripts(node, size, type: :script)
        base = build_node(node[:base], size, type)
        upper = build_optional(node[:upper], size * SCRIPT_SCALE)
        lower = build_optional(node[:lower], size * SCRIPT_SCALE)
        x = base.width
        upper_y =
          if upper
            [base.height * 0.45, upper.depth + 0.08 * size].max
          end
        lower_y =
          if lower
            [-0.25 * size, -lower.height - 0.05 * size].min
          end

        children = [[base, 0.0, 0.0]]
        children << [upper, x, upper_y] if upper
        children << [lower, x, lower_y] if lower
        box = assemble_box(type, children, node)
        box.details.update(script_size: size * SCRIPT_SCALE)
        box
      end

      def build_optional(node, size)
        return nil if empty_node?(node)

        build_node(node, size, :script)
      end

      def empty_node?(node)
        node.nil? ||
          (node.is_a?(Array) && (node.empty? || node.all? { |item|
            empty_node?(item)
          }))
      end

      def build_operator_node(name, upper_node, lower_node, size, source = nil)
        operator = OPERATORS.fetch(name)
        font = font_for(:normal)
        verify_glyphs(font, operator)
        unit = text_metrics(font, operator, 1.0)
        glyph_size = (OPERATOR_SCALE * size) / (unit[:height] + unit[:depth])
        glyph = build_text(operator, :normal, glyph_size)
        glyph_y =
          0.25 * size - (glyph.height - glyph.depth) / 2.0

        upper = build_optional(upper_node, size * SCRIPT_SCALE)
        lower = build_optional(lower_node, size * SCRIPT_SCALE)
        gap = 0.08 * size
        width = [glyph.width, upper&.width || 0, lower&.width || 0].max
        upper_y = glyph_y + glyph.height + gap + upper.depth if upper
        lower_y = glyph_y - glyph.depth - gap - lower.height if lower

        children = [[glyph, (width - glyph.width) / 2.0, glyph_y]]
        children << [upper, (width - upper.width) / 2.0, upper_y] if upper
        children << [lower, (width - lower.width) / 2.0, lower_y] if lower
        box = assemble_box(:operator, children, source || { op: name })
        box.details.update(operator: name, glyph_size: glyph_size)
        box
      end

      def draw_box(box, origin_x, origin_y)
        draw_thing(box, origin_x, origin_y)
        box.children.each do |child|
          draw_box(
            child,
            origin_x + child.x,
            origin_y + child.y,
          )
        end
      end

      def draw_thing(box, x, y)
        case box.drawing&.dig(:kind)
        when :text
          document.draw_text(
            box.drawing[:value],
            at: [x, y],
            size: box.drawing[:size],
            style: box.drawing[:style],
          )
        when :fraction
          line = box.drawing[:thickness]
          stroke_path(line) do
            document.line(
              x,
              y + box.drawing[:y],
              x + box.width,
              y + box.drawing[:y],
            )
          end
        when :sqrt
          draw_radical(box.drawing, x, y)
        end
      end

      def draw_radical(drawing, x, y)
        line = drawing[:line]
        stroke_path(line) do
          points = drawing[:points]
          document.move_to(x + points[0][0], y + points[0][1])
          points[1..].each do |point|
            document.line_to(x + point[0], y + point[1])
          end

          bar = drawing[:overbar]
          document.move_to(x + bar[0], y + bar[1])
          document.line_to(x + bar[2], y + bar[1])
        end
      end

      def stroke_path(line)
        previous_cap_style = document.cap_style
        previous_join_style = document.join_style
        document.line_width = line
        document.cap_style = :projecting_square
        document.join_style = :miter
        document.stroke { yield }
        document.cap_style = previous_cap_style
        document.join_style = previous_join_style
      end

      def stroke_debug(box, x, y)
        document.stroke_color = 'd62728'
        document.line_width = 0.4
        box.traversal do |item|
          top = y + item.y + item.height
          document.stroke_rectangle(
            [x + item.x, top],
            item.width,
            item.height + item.depth,
          )
          document.line(
            x + item.x,
            y + item.y,
            x + item.x + item.width,
            y + item.y,
          )
        end
      end

      def assemble_box(type, children, source)
        box = Box.new(type: type, width: 0, height: 0, depth: 0)
        identify(box, source.is_a?(Hash) ? source : nil)
        children.each do |child, x, y|
          box.add_child(child, x, y)
        end
        size_box_to_children(box, children.map(&:first))
        box
      end
    end
  end
end
