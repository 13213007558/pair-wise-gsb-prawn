# frozen_string_literal: true

module Prawn
  module Math
    # A laid-out piece of a formula. Every box knows its width, its
    # height above the baseline and its depth below the baseline, and
    # can render itself with its left edge at +x+ and its baseline at
    # +baseline+ (both in the document's current user space).
    class Box
      # Width of the box in points.
      attr_reader :width

      # Height of the box above the baseline in points.
      attr_reader :height

      # Depth of the box below the baseline in points.
      attr_reader :depth

      def initialize(width, height, depth)
        @width = width
        @height = height
        @depth = depth
      end

      # Atom type used for inter-atom spacing (:ord, :rel, :bin, :op).
      def atom
        :ord
      end

      # Short type name used in debug manifests.
      def kind
        :box
      end

      # Human-readable label used in debug manifests.
      def label
        kind.to_s
      end

      # Child boxes with their offsets relative to this box's origin
      # (left edge, baseline): [[box, dx, dy], ...].
      def children
        []
      end

      # Renders the box. +x+ is the left edge and +baseline+ the baseline
      # y-coordinate, both in the document's current user space.
      def render(pdf, x, baseline)
        raise NotImplementedError
      end

      # Bounding box [x, y, width, height] when rendered at the given
      # position. y is the bottom edge.
      def bounds_at(x, baseline)
        [x, baseline - depth, width, height + depth]
      end

      # Walks this box and all descendants, yielding
      # [box, x, baseline] with absolute coordinates for the given
      # placement. Useful for drawing debug frames and for independent
      # verification of positions.
      def each_box(x, baseline)
        return enum_for(:each_box, x, baseline) unless block_given?
        yield self, x, baseline
        children.each do |child, dx, dy|
          child.each_box(x + dx, baseline + dy) do |*args|
            yield(*args)
          end
        end
      end
    end
  end
end
