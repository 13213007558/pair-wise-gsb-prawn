# frozen_string_literal: true

module Prawn
  module Graphics
    # Implements spot color handling via Separation and DeviceN color spaces.
    #
    # Spot colors are used in print production to reproduce colors that can
    # not (or should not) be built from process colorants, e.g. brand colors
    # or Pantone inks. Instead of flattening them to RGB/CMYK values, the
    # colorant is named in the PDF along with an alternate color space and
    # a tint transform that is only used for preview and for devices that do
    # not have the colorant.
    module SpotColor
      # Alternate color spaces supported for spot color definitions along
      # with their component counts.
      # @private
      ALTERNATE_COLOR_SPACES = {
        DeviceGray: 1,
        DeviceRGB: 3,
        DeviceCMYK: 4,
      }.freeze

      # A declared Separation or DeviceN color space.
      #
      # Instances are returned by {Prawn::Document#register_separation} and
      # {Prawn::Document#register_device_n} and can be passed to
      # {Prawn::Document#fill_spot_color} and
      # {Prawn::Document#stroke_spot_color}.
      class SpotColorSpace
        # Type of the color space: +:separation+ or +:device_n+.
        attr_reader :type

        # Colorant names.
        # @return [Array<String>]
        attr_reader :names

        # Alternate color space.
        # @return [Symbol]
        attr_reader :alternate

        # Name of the color space in page resource dictionaries.
        # @return [String]
        attr_reader :resource_name

        # Normalized tint transform specification.
        # @private
        attr_reader :tint_transform_spec

        # @private
        def initialize(type, names, alternate, tint_transform_spec, resource_name)
          @type = type
          @names = names
          @alternate = alternate
          @tint_transform_spec = tint_transform_spec
          @resource_name = resource_name
        end

        # Number of colorants (and thus tint values) of this color space.
        #
        # @return [Integer]
        def components
          names.length
        end

        # Definition of this color space used to detect conflicting
        # registrations.
        #
        # @private
        def definition_key
          [type, names, alternate, tint_transform_spec]
        end
      end

      # A color in a Separation or DeviceN color space: a color space along
      # with tint values for each of its colorants.
      class SpotColorValue
        # Color space.
        # @return [SpotColorSpace]
        attr_reader :space

        # Tint values, one per colorant, in the range 0..1.
        # @return [Array<Float>]
        attr_reader :tints

        # @private
        def initialize(space, tints)
          @space = space
          @tints = tints.map { |tint| Float(tint) }.freeze
        end
      end

      # @group Experimental API

      # Declares a Separation color space for a single spot colorant.
      #
      # The tint transform maps a single tint value (0–1) to the alternate
      # color space. It can be specified either as a linear interpolation
      # between two alternate color values (+c0+ for tint 0 and +c1+ for
      # tint 1) or as an explicit tint transform (see
      # {#register_device_n} for the accepted forms).
      #
      # Registering the same colorant name again with an identical
      # definition returns the already registered color space. Registering
      # it with a different definition raises
      # {Prawn::Errors::IncompatibleSpotColor} instead of silently
      # overriding the previous declaration.
      #
      # @example
      #   red = pdf.register_separation(
      #     'Brand Red',
      #     alternate: :DeviceCMYK,
      #     c1: [0, 100, 85, 5],
      #   )
      #   pdf.fill_spot_color(red, 0.75)
      #
      # @param name [String] colorant name (e.g. a Pantone name)
      # @param alternate [Symbol] alternate color space:
      #   +:DeviceGray+, +:DeviceRGB+, or +:DeviceCMYK+
      # @param c0 [Array<Number>] alternate color components at tint 0,
      #   defaults to all zeroes
      # @param c1 [Array<Number>] alternate color components at tint 1
      # @param tint_transform [String, Hash, PDF::Core::Reference]
      #   explicit tint transform, mutually exclusive with +c0+/+c1+
      # @return [SpotColorSpace]
      def register_separation(
        name,
        alternate: :DeviceCMYK,
        c0: nil,
        c1: nil,
        tint_transform: nil
      )
        components = alternate_components(alternate)

        if tint_transform
          if c0 || c1
            raise ArgumentError,
              'pass either c0/c1 or tint_transform, not both'
          end
          tint_spec = normalize_tint_transform(tint_transform)
        else
          unless c1
            raise ArgumentError, 'either c1 or tint_transform is required'
          end
          c0 ||= [0] * components
          validate_alternate_color(c0, components, 'c0')
          validate_alternate_color(c1, components, 'c1')
          tint_spec = [:interpolation, c0.map { |v| Float(v) }, c1.map { |v| Float(v) }]
        end

        register_spot_color_space(
          :separation,
          [validate_colorant_name(name)],
          alternate,
          tint_spec,
        )
      end

      # Declares a DeviceN color space mixing several spot colorants.
      #
      # The tint transform maps one tint value per colorant to the alternate
      # color space. It can be specified as:
      #
      # - a String containing a PostScript calculator function (PDF function
      #   type 4), e.g. <tt>'{ exch 0.5 mul add }'</tt>
      # - a Hash describing an arbitrary PDF function dictionary
      # - a +PDF::Core::Reference+ to a function object
      #
      # Registering the same set of colorant names again with an identical
      # definition returns the already registered color space. Registering
      # them with a different definition raises
      # {Prawn::Errors::IncompatibleSpotColor} instead of silently
      # overriding the previous declaration.
      #
      # @example
      #   mix = pdf.register_device_n(
      #     ['Brand Red', 'Brand Yellow'],
      #     alternate: :DeviceCMYK,
      #     tint_transform: '{ 2 copy 0.25 mul add 3 1 roll ... }',
      #   )
      #   pdf.fill_spot_color(mix, 0.5, 0.25)
      #
      # @param names [Array<String>] colorant names
      # @param alternate [Symbol] alternate color space:
      #   +:DeviceGray+, +:DeviceRGB+, or +:DeviceCMYK+
      # @param tint_transform [String, Hash, PDF::Core::Reference]
      #   tint transform function
      # @return [SpotColorSpace]
      def register_device_n(names, alternate: :DeviceCMYK, tint_transform: nil)
        alternate_components(alternate)

        unless names.is_a?(Array) && names.any?
          raise ArgumentError, 'at least one colorant name is required'
        end
        unless tint_transform
          raise ArgumentError, 'tint_transform is required'
        end

        register_spot_color_space(
          :device_n,
          names.map { |name| validate_colorant_name(name) },
          alternate,
          normalize_tint_transform(tint_transform),
        )
      end

      # Sets the fill color to a tint (or tints) of a registered spot color
      # space.
      #
      # @example
      #   pdf.fill_spot_color(red, 0.75)
      #   pdf.fill_spot_color(mix, 0.5, 0.25)
      #
      # @param space [SpotColorSpace, String] a color space returned by
      #   {#register_separation} or {#register_device_n}, or the colorant
      #   name of a registered separation
      # @param tints [Array<Number>] tint values (0–1), one per colorant
      # @return [void]
      def fill_spot_color(space, *tints)
        self.current_fill_color = spot_color_value(space, tints)
        set_fill_color
      end

      # Sets the stroke color to a tint (or tints) of a registered spot
      # color space.
      #
      # @example
      #   pdf.stroke_spot_color(red, 1)
      #   pdf.stroke_spot_color(mix, 0.5, 0.25)
      #
      # @param space [SpotColorSpace, String] a color space returned by
      #   {#register_separation} or {#register_device_n}, or the colorant
      #   name of a registered separation
      # @param tints [Array<Number>] tint values (0–1), one per colorant
      # @return [void]
      def stroke_spot_color(space, *tints)
        self.current_stroke_color = spot_color_value(space, tints)
        set_stroke_color
      end

      private

      # All spot color spaces declared in this document, indexed by colorant
      # names.
      def spot_color_registry
        @spot_color_registry ||= {}
      end

      def register_spot_color_space(type, names, alternate, tint_spec)
        key = [type, names]
        existing = spot_color_registry[key]

        if existing
          if existing.alternate == alternate &&
              existing.tint_transform_spec == tint_spec
            return existing
          end

          raise Prawn::Errors::IncompatibleSpotColor,
            "spot color #{names.join(' + ').inspect} is already registered " +              'with a different definition'
        end

        space = SpotColorSpace.new(
          type,
          names,
          alternate,
          tint_spec,
          next_spot_color_resource_name,
        )
        spot_color_registry[key] = space
        space
      end

      def next_spot_color_resource_name
        @spot_color_counter = (@spot_color_counter || 0) + 1
        "CS#{@spot_color_counter}"
      end

      def spot_color_value(space, tints)
        space = resolve_spot_color_space(space)

        if tints.length != space.components
          raise ArgumentError,
            "wrong number of tints: #{tints.length} for " +              "#{space.components} colorant(s)"
        end

        tints.each do |tint|
          unless (0..1).cover?(tint)
            raise ArgumentError, "tint values must be between 0 and 1: #{tint}"
          end
        end

        SpotColorValue.new(space, tints)
      end

      def resolve_spot_color_space(space)
        case space
        when SpotColorSpace
          space
        when String
          registered = spot_color_registry[[:separation, [space]]]
          unless registered
            raise ArgumentError, "unknown spot color: #{space.inspect}"
          end
          registered
        else
          raise ArgumentError, "unknown spot color space: #{space.inspect}"
        end
      end

      def validate_colorant_name(name)
        unless name.is_a?(String) && !name.empty?
          raise ArgumentError, "colorant name must be a non-empty String: #{name.inspect}"
        end
        name
      end

      def alternate_components(alternate)
        ALTERNATE_COLOR_SPACES.fetch(alternate) do
          raise ArgumentError, "unknown alternate color space: #{alternate.inspect}"
        end
      end

      def validate_alternate_color(color, components, name)
        unless color.is_a?(Array) && color.length == components
          raise ArgumentError,
            "#{name} must have #{components} component(s) for the alternate color space"
        end
      end

      def normalize_tint_transform(tint_transform)
        case tint_transform
        when String
          [:calculator, tint_transform]
        when Hash
          [:function, tint_transform]
        when PDF::Core::Reference
          [:reference, tint_transform.identifier]
        else
          raise ArgumentError,
            "unknown tint transform: #{tint_transform.inspect}"
        end
      end

      # Reference to the color space definition array, shared by all pages
      # that use this color space.
      def spot_color_definition_ref(space)
        @spot_color_definitions ||= {}
        @spot_color_definitions[space.resource_name] ||= ref!(
          case space.type
          when :separation
            [
              :Separation,
              space.names.first.to_sym,
              space.alternate,
              spot_tint_transform_ref(space),
            ]
          when :device_n
            [
              :DeviceN,
              space.names.map(&:to_sym),
              space.alternate,
              spot_tint_transform_ref(space),
            ]
          end,
        )
      end

      def spot_tint_transform_ref(space)
        domain = [0.0, 1.0] * space.components
        range = [0.0, 1.0] * ALTERNATE_COLOR_SPACES.fetch(space.alternate)

        kind, *payload = space.tint_transform_spec

        case kind
        when :interpolation
          c0, c1 = payload
          ref!(
            FunctionType: 2,
            Domain: domain,
            C0: c0,
            C1: c1,
            N: 1.0,
          )
        when :calculator
          code = payload.first
          function = ref!(
            FunctionType: 4,
            Domain: domain,
            Range: range,
          )
          function.stream << code
          function
        when :function
          ref!({ Domain: domain }.merge(payload.first))
        when :reference
          identifier = payload.first
          renderer.state.store[identifier]
        end
      end

      def ensure_spot_color_resource(space)
        color_spaces = page.resources[:ColorSpace] ||= {}
        color_spaces[space.resource_name] ||= spot_color_definition_ref(space)
      end

      def set_spot_color(type, value, operator)
        ensure_spot_color_resource(value.space)
        set_spot_color_space(type, value.space.resource_name)
        write_color(PDF::Core.real_params(value.tints), operator)
      end

      def set_spot_color_space(type, resource_name)
        # don't set the same color space again
        if current_color_space(type) == resource_name &&
            !state.page.in_stamp_stream?
          return
        end

        set_current_color_space(resource_name, type)

        operator =
          case type
          when :fill
            'cs'
          when :stroke
            'CS'
          else
            raise ArgumentError, "unknown type '#{type}'"
          end

        renderer.add_content("/#{resource_name} #{operator}")
      end
    end
  end
end
