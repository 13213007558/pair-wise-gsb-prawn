# frozen_string_literal: true

module Prawn
  module Formula
    # A measured math box. Coordinates are relative to the parent box's
    # baseline origin; the box's own baseline is at y = 0.
    class Box
      attr_accessor :id, :label, :type, :x, :y, :width, :height, :depth
      attr_accessor :font_family
      attr_reader :children, :details
      attr_accessor :drawing

      def initialize(type:, width:, height:, depth:, label: nil, id: nil)
        @id = id
        @label = label
        @type = type
        @x = 0
        @y = 0
        @width = width.to_f
        @height = height.to_f
        @depth = depth.to_f
        @children = []
        @details = {}
        @drawing = nil
      end

      def add_child(box, x, y)
        box.x = x.to_f
        box.y = y.to_f
        children << box
        box
      end

      def traversal(&block)
        yield self
        children.each { |child| child.traversal(&block) }
      end

      def flat
        list = []
        traversal { |box| list << box }
        list
      end

      def report(origin_x = 0, origin_y = 0)
        entries(self, origin_x, origin_y, nil)
      end

      def to_h
        {
          id: id,
          label: label,
          type: type,
          x: x,
          baseline_y: y,
          width: width,
          height: height,
          depth: depth,
          font_family: font_family,
          details: details,
          children: children.map(&:to_h),
        }
      end

      private

      def entries(box, origin_x, origin_y, parent)
        [entry(box, origin_x, origin_y, parent)] +
          box.children.flat_map do |child|
            entries(
              child,
              origin_x + child.x,
              origin_y + child.y,
              box,
            )
          end
      end

      def entry(box, origin_x, origin_y, parent)
        absolute_x = origin_x
        absolute_y = origin_y
        {
          id: box.id,
          label: box.label,
          type: box.type,
          parent: parent&.id,
          local: {
            x: box.x,
            baseline_y: box.y,
            width: box.width,
            height: box.height,
            depth: box.depth,
            left: box.x,
            right: box.x + box.width,
            top: box.y + box.height,
            bottom: box.y - box.depth,
          },
          page: {
            origin_x: absolute_x,
            baseline_y: absolute_y,
            left: absolute_x,
            right: absolute_x + box.width,
            top: absolute_y + box.height,
            bottom: absolute_y - box.depth,
          },
        }.merge(box.details)
      end
    end
  end
end
