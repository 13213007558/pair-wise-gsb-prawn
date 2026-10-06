# frozen_string_literal: true

module Prawn
  module Graphics
    # Implements spot color support via Separation and DeviceN color spaces.
    #
    # Spot colors are used in print production to keep named inks (for
    # example PANTONE colors) as independent channels in the generated PDF
    # instead of flattening them to process colors.
    module SpotColor
      # A spot color space declared with {SpotColor#declare_spot_color}.
      #
      # A single-channel color space is emitted as a +/Separation+ color
      # space, a multi-channel one as a +/DeviceN+ color space.
      class SpotColorSpace
        # Name of this color space in page resources.
        # @return [Symbol]
        attr_reader :resource_name

        # Number of colorant channels of this color space.
        # @return [Integer]
        attr_reader :channel_count

        # @private
        # @return [PDF::Core::Reference]
        attr_reader :reference

        # @private
        def initialize(resource_name, channel_count, reference)
          @resource_name = resource_name
          @channel_count = channel_count
          @reference = reference
        end

        # @private
        def ==(other)
          other.is_a?(SpotColorSpace) &&
            other.resource_name == resource_name
        end
      end

      # A color value in a declared spot color space. Values of this class
      # can also be passed to {Color#fill_color} and {Color#stroke_color}.
      class SpotColorValue
        # Color space of this color.
        # @return [SpotColorSpace]
        attr_reader :color_space

        # Channel (tint) values of this color, one per colorant channel.
        # Each value is between 0 and 1.
        # @return [Array<Numeric>]
        attr_reader :tints

        # @private
        def initialize(color_space, tints)
          @color_space = color_space
          @tints = tints.freeze
        end

        # @private
        def ==(other)
          other.is_a?(SpotColorValue) &&
            other.color_space == color_space &&
            other.tints == tints
        end
      end

      # @group Experimental API

      # Declares a spot color space and returns a handle that can be used
      # with {fill_spot_color} and {stroke_spot_color}.
      #
      # A single colorant name produces a +/Separation+ color space,
      # multiple names a +/DeviceN+ color space:
      #
      #   pantone_red = pdf.declare_spot_color(
      #     'PANTONE 185 C',
      #     alternate: [0, 100, 93, 0],
      #   )
      #
      #   duotone = pdf.declare_spot_color(
      #     ['PANTONE 185 C', 'PANTONE 300 C'],
      #     alternate: [0, 100, 93, 0],
      #     tint_transform: '{ 1 exch sub 0.93 mul exch 1 exch sub 0.56 mul 0 0.18 }',
      #   )
      #
      # Color spaces are deduplicated by their full definition: declaring
      # the same colorant names with the same alternate color and tint
      # transform reuses the previously created PDF object, while the same
      # names with a different tint transform produce an independent color
      # space.
      #
      # @param names [String, Array<String>]
      #   Colorant (channel) names. A single name declares a +/Separation+
      #   color space, multiple names a +/DeviceN+ color space.
      # @param alternate [String, Array<Number>]
      #   Alternate color used for preview and for consumers that can't
      #   handle spot colors. Either a 6 digit HTML color code or 3 RGB
      #   components (0-255) for a DeviceRGB alternate, or 4 CMYK
      #   components (0-100) for a DeviceCMYK alternate.
      # @param tint_transform [Hash, String, nil]
      #   Function mapping tint values to the alternate color space.
      #   Supported forms:
      #   - +nil+ (only for single-channel color spaces): a linear
      #     interpolation from white to the alternate color.
      #   - a Hash describing a Type 2 (exponential interpolation)
      #     function: +{ type: 2, c0: [...], c1: [...], n: 1 }+. Only valid
      #     for single-channel color spaces.
      #   - a String of PostScript code for a Type 4 (PostScript
      #     calculator) function, for example +'{ dup 0.5 mul }'+.
      #
      #   Anything else is rejected with an +ArgumentError+.
      # @return [SpotColorSpace]
      def declare_spot_color(names, alternate:, tint_transform: nil)
        names = Array(names)

        if names.empty?
          raise ArgumentError, 'at least one colorant name is required'
        end

        alternate_components = spot_alternate_components(alternate)
        alternate_color_space = spot_alternate_color_space(alternate)

        function =
          spot_tint_transform(tint_transform, names.length, alternate_components)

        key = [names, alternate_components, function[:key]]

        spot_color_registry[key] ||= begin
          function_ref = build_spot_function(
            function,
            names.length,
            alternate_components.length,
          )

          reference =
            if names.length == 1
              ref!(
                [
                  :Separation,
                  names.first.to_sym,
                  alternate_color_space,
                  function_ref,
                ],
              )
            else
              ref!(
                [
                  :DeviceN,
                  names.map { |name| name.to_sym },
                  alternate_color_space,
                  function_ref,
                ],
              )
            end

          SpotColorSpace.new(
            :"CS#{spot_color_registry.length + 1}",
            names.length,
            reference,
          )
        end
      end

      # Sets the fill color to a tint (or tints) of a declared spot color
      # space.
      #
      #   pantone_red = pdf.declare_spot_color(
      #     'PANTONE 185 C',
      #     alternate: [0, 100, 93, 0],
      #   )
      #   pdf.fill_spot_color(pantone_red, 0.75)
      #
      # @param color_space [SpotColorSpace]
      #   A color space returned by {declare_spot_color}.
      # @param tints [Array<Numeric>]
      #   One tint value per colorant channel, each between 0 and 1.
      # @return [void]
      def fill_spot_color(color_space, *tints)
        self.current_fill_color = spot_color_value(color_space, tints)
        set_fill_color
      end

      # Sets the stroking color to a tint (or tints) of a declared spot
      # color space.
      #
      #   pantone_red = pdf.declare_spot_color(
      #     'PANTONE 185 C',
      #     alternate: [0, 100, 93, 0],
      #   )
      #   pdf.stroke_spot_color(pantone_red, 1)
      #
      # @param color_space [SpotColorSpace]
      #   A color space returned by {declare_spot_color}.
      # @param tints [Array<Numeric>]
      #   One tint value per colorant channel, each between 0 and 1.
      # @return [void]
      def stroke_spot_color(color_space, *tints)
        self.current_stroke_color = spot_color_value(color_space, tints)
        set_stroke_color
      end

      private

      def spot_color_registry
        @spot_color_registry ||= {}
      end

      def spot_color_space?(name)
        spot_color_registry.any? { |_, space| space.resource_name == name }
      end

      def register_spot_color_space(color)
        color_spaces = page.resources[:ColorSpace] ||= {}
        color_spaces[color.color_space.resource_name] =
          color.color_space.reference
      end

      def spot_color_value(color_space, tints)
        unless color_space.is_a?(SpotColorSpace)
          raise ArgumentError,
            'expected a spot color space declared with declare_spot_color, ' \
              "got: #{color_space.inspect}"
        end

        tints = tints.flatten

        if tints.length != color_space.channel_count
          raise ArgumentError,
            "wrong number of tint values: got #{tints.length}, expected " \
              "#{color_space.channel_count}"
        end

        tints.each do |tint|
          unless tint.is_a?(Numeric) && (0..1).cover?(tint)
            raise ArgumentError,
              "tint values must be numbers between 0 and 1, got: #{tint.inspect}"
          end
        end

        SpotColorValue.new(color_space, tints)
      end

      def spot_alternate_components(alternate)
        case color_type(alternate)
        when :RGB
          components =
            if alternate.is_a?(String)
              Color.hex2rgb(alternate)
            else
              alternate
            end
          components.map { |component| component / 255.0 }
        when :CMYK
          alternate.map { |component| component / 100.0 }
        end
      end

      def spot_alternate_color_space(alternate)
        case color_type(alternate)
        when :RGB
          :DeviceRGB
        when :CMYK
          :DeviceCMYK
        end
      end

      def spot_tint_transform(transform, channel_count, alternate_components)
        spec =
          case transform
          when nil
            if channel_count > 1
              raise ArgumentError,
                'multi-channel (DeviceN) color spaces require an explicit ' \
                  'tint transform'
            end

            c0 = spot_white(alternate_components)

            {
              type: 2,
              c0: c0,
              c1: alternate_components,
              n: 1,
              key: [:t2, c0, alternate_components, 1],
            }
          when Hash
            spot_tint_transform_hash(transform, alternate_components)
          when String
            { type: 4, code: transform, key: [:t4, transform] }
          else
            raise ArgumentError,
              "unsupported tint transform: #{transform.inspect}; supported " \
                'forms are a Hash (Type 2 exponential interpolation ' \
                'function) or a String (Type 4 PostScript calculator function)'
          end

        if spec[:type] == 2 && channel_count > 1
          raise ArgumentError,
            'Type 2 tint transforms only support a single colorant channel; ' \
              'use a Type 4 PostScript calculator function instead'
        end

        spec
      end

      def spot_tint_transform_hash(transform, alternate_components)
        unless transform[:type] == 2
          raise ArgumentError,
            "unsupported tint transform function type: #{transform[:type].inspect}"
        end

        c0 = transform.fetch(:c0)
        c1 = transform.fetch(:c1)
        n = transform.fetch(:n, 1)

        [c0, c1].each do |components|
          unless components.is_a?(Array) &&
              components.length == alternate_components.length &&
              components.all? { |component| component.is_a?(Numeric) }
            raise ArgumentError,
              'tint transform endpoints must be arrays of ' \
                "#{alternate_components.length} numbers"
          end
        end

        unless n.is_a?(Numeric)
          raise ArgumentError,
            "tint transform exponent must be a number, got: #{n.inspect}"
        end

        { type: 2, c0: c0, c1: c1, n: n, key: [:t2, c0, c1, n] }
      end

      def build_spot_function(spec, channel_count, alternate_component_count)
        case spec[:type]
        when 2
          ref!(
            FunctionType: 2,
            Domain: [0.0, 1.0],
            C0: spec[:c0],
            C1: spec[:c1],
            N: spec[:n],
          )
        when 4
          function = ref!(
            FunctionType: 4,
            Domain: [0.0, 1.0] * channel_count,
            Range: [0.0, 1.0] * alternate_component_count,
          )
          function << spec[:code]
          function
        end
      end

      def spot_white(alternate_components)
        if alternate_components.length == 4
          [0.0, 0.0, 0.0, 0.0]
        else
          [1.0, 1.0, 1.0]
        end
      end
    end
  end
end
