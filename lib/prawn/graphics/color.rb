# frozen_string_literal: true

module Prawn
  module Graphics
    # Implements color handling.
    module Color
      # @group Stable API

      # A color space stored in a page's +/ColorSpace+ resource dictionary.
      class DefinedColorSpace
        attr_reader :family, :names, :alternate_color_space, :tint_transform,
                    :attributes, :resource_name

        def initialize(
          family, names, alternate_color_space, tint_transform,
          reference, resource_name, attributes = nil
        )
          @family = family
          @names = names.freeze
          @alternate_color_space = alternate_color_space
          @tint_transform = tint_transform
          @reference = reference
          @resource_name = resource_name
          @attributes = attributes

          freeze
        end

        def color(*tints)
          tints = tints.flatten
          tints = Array.new(names.length, 1.0) if tints.empty?

          unless tints.length == names.length
            raise ArgumentError,
              "expected #{names.length} tint value(s), got #{tints.length}"
          end

          unless tints.all?(Numeric) && tints.all? { |tint| (0..1).cover?(tint) }
            raise ArgumentError, 'tint values must be numbers between 0 and 1'
          end

          SpecialColor.new(self, tints.freeze)
        end

        def components
          names
        end

        def specification
          {
            family: family,
            names: names,
            alternate_color_space: alternate_color_space,
            tint_transform: tint_transform_specification,
            attributes: attributes,
          }
        end

        def ==(other)
          other.is_a?(self.class) && other.specification == specification
        end

        alias eql? ==

        def hash
          specification.hash
        end

        def to_pdf
          @reference
        end

        private

        def tint_transform_specification
          if @tint_transform.is_a?(::Hash)
            specification = @tint_transform.reject do |key|
              %i[stream program].include?(key)
            end
            program = @tint_transform[:stream] || @tint_transform[:program]
            specification[:stream] = program if program
            specification
          else
            specification = @tint_transform.data.dup
            program = @tint_transform.stream.filtered_stream
            specification[:stream] = program if program
            specification
          end
        end
      end

      # A color value in a {DefinedColorSpace}.
      class SpecialColor
        attr_reader :color_space, :tints

        def initialize(color_space, tints)
          @color_space = color_space
          @tints = tints
          freeze
        end

        def ==(other)
          other.is_a?(self.class) &&
            other.color_space == color_space &&
            other.tints == tints
        end

        alias eql? ==

        def hash
          [color_space, tints].hash
        end
      end

      # Declares a Separation color space for one spot colorant.
      #
      # Re-declaring the same colorant with an identical alternate color
      # space and tint transform returns the existing definition. An
      # inconsistent re-declaration raises ArgumentError.
      #
      # @example
      #   brand_red = pdf.define_separation_color_space(
      #     :BrandRed, :DeviceRGB,
      #     FunctionType: 2,
      #     Domain: [0.0, 1.0],
      #     C0: [0.0, 0.0, 0.0],
      #     C1: [1.0, 0.0, 0.0],
      #     N: 1.0,
      #   )
      #   pdf.fill_color(brand_red, 0.75)
      #
      # @param name [Symbol, String] spot colorant name
      # @param alternate_color_space [Symbol, Array] alternate color space
      # @param tint_transform [Hash, PDF::Core::Reference] PDF function used
      #   to map the tint into the alternate color space
      # @return [DefinedColorSpace]
      def define_separation_color_space(
        name, *arguments,
        alternate_color_space: nil, alternate: nil, tint_transform: nil
      )
        alternate_color_space ||=
          normalize_alternate_color_space(
            alternate || arguments[0] || :DeviceRGB
          )
        tint_transform ||= arguments[1]

        name = normalize_colorant_name(name)
        definition = DefinedColorSpace.new(
          :Separation, [name], alternate_color_space,
          normalize_tint_transform_input(tint_transform), nil, nil
        )

        if (existing = separation_color_spaces[name]) && existing != definition
          raise ArgumentError,
            "spot color #{name.inspect} is already defined with a different " \
              'alternate color space or tint transform'
        end

        separation_color_spaces[name] ||=
          create_defined_color_space(definition)
      end

      alias separation_color_space define_separation_color_space
      alias define_separation define_separation_color_space

      # Declares a DeviceN color space for one or more spot colorants.
      #
      # DeviceN definitions with different transforms receive distinct
      # resource names, so they cannot silently replace one another.
      #
      # @example
      #   mix = pdf.define_device_n_color_space(
      #     [:BrandRed, :BrandBlue],
      #     alternate_color_space: :DeviceRGB,
      #     tint_transform: {
      #       FunctionType: 4,
      #       Domain: [0.0, 1.0, 0.0, 1.0],
      #       Range: [0.0, 1.0] * 3,
      #       stream: '{ 1 index 0 }',
      #     },
      #   )
      #   pdf.fill_color(mix, 0.25, 0.75)
      #
      # @param names [Array<Symbol, String>] spot colorant names
      # @param alternate_color_space [Symbol, Array] alternate color space
      # @param tint_transform [Hash, PDF::Core::Reference] PDF function used
      #   to map all tints into the alternate color space
      # @param attributes [Hash, nil] optional DeviceN attributes dictionary
      # @return [DefinedColorSpace]
      def define_device_n_color_space(
        names, *arguments,
        alternate_color_space: nil, alternate: nil,
        tint_transform: nil, attributes: nil
      )
        alternate_color_space ||=
          normalize_alternate_color_space(
            alternate || arguments[0] || :DeviceRGB
          )
        tint_transform ||= arguments[1]
        attributes ||= arguments[2]

        names = Array(names).flatten.map { |name| normalize_colorant_name(name) }
        if names.empty?
          raise ArgumentError, 'DeviceN color spaces require at least one name'
        end

        definition = DefinedColorSpace.new(
          :DeviceN, names, alternate_color_space,
          normalize_tint_transform_input(tint_transform), nil, nil, attributes
        )

        device_n_color_spaces[definition.specification] ||=
          create_defined_color_space(definition)
      end

      alias device_n_color_space define_device_n_color_space
      alias define_device_n define_device_n_color_space

      # Sets or returns the fill color.
      #
      # @overload fill_color
      #   Returns the current fill color.
      #
      #   @return [String, Array<Number>]
      #
      # @overload fill_color(color)
      #   Sets the fill color.
      #
      #   If a single argument is provided, it should be a 6 digit HTML color
      #   code.
      #
      #   ```ruby
      #   pdf.fill_color "f0ffc1"
      #   ```
      #
      #   If 4 arguments are provided, the color is assumed to be a CMYK value.
      #   Values range is 0–100.
      #
      #   ```ruby
      #   pdf.fill_color 0, 99, 95, 0
      #   ```
      #
      #   @param color [String, Array<Number>]
      #   @return [void]
      def fill_color(*color)
        return current_fill_color if color.empty?

        self.current_fill_color = process_color(*color)
        set_fill_color
      end

      alias fill_color= fill_color

      # Sets or returns the line stroking color.
      #
      # @overload stroke_color
      #   When called with no argument, it returns the current stroking color.
      #
      #   @return [String, Array<Number>]
      #
      # @overload stroke_color(color)
      #   Sets the stroking color.
      #
      #   @param color [String, Array<Number>] new stroking color:
      #     - In String form it should be a 6 digit HTML color code.
      #
      #       ```ruby
      #       pdf.stroke_color "f0ffc1"
      #       ```
      #     - If 4 arguments are provided, the color is assumed to be a CMYK
      #       value. Values range from 0 to 100.
      #
      #       ```ruby
      #       pdf.stroke_color 0, 99, 95, 0
      #       ```
      #   @return [void]
      def stroke_color(*color)
        return current_stroke_color if color.empty?

        color = process_color(*color)
        self.current_stroke_color = color
        set_stroke_color(color)
      end

      alias stroke_color= stroke_color

      module_function

      # Converts RGB value array to hex string suitable for use with
      # {fill_color} and {stroke_color}.
      #
      # @example
      #   Prawn::Graphics::Color.rgb2hex([255, 120, 8])
      #   #=> "ff7808"
      #
      # @param rgb [Array(Number, Number, Number)]
      #   Each component has to be in the range from 0 to 255.
      # @return [String]
      def rgb2hex(rgb)
        rgb.map { |e| format('%<value>02x', value: e) }.join
      end

      # Converts hex string into RGB value array.
      #
      # @example
      #   Prawn::Graphics::Color.hex2rgb("ff7808")
      #   #=> [255, 120, 8]
      #
      # @param hex [String] must be 6-digits long.
      # @return [Array(Integer, Integer, Integer)]
      def hex2rgb(hex)
        r = hex[0..1]
        g = hex[2..3]
        b = hex[4..5]
        [r, g, b].map { |e| e.to_i(16) }
      end

      private

      def normalize_colorant_name(name)
        case name
        when Symbol, String
          raise ArgumentError, 'colorant name cannot be empty' if name.empty?

          name.to_sym
        else
          raise ArgumentError, "invalid colorant name: #{name.inspect}"
        end
      end

      def normalize_alternate_color_space(color_space)
        case color_space
        when String
          color_space.to_sym
        when Array
          color_space.map do |item|
            item.is_a?(String) ? item.to_sym : item
          end
        else
          color_space
        end
      end

      def normalize_tint_transform_input(tint_transform)
        case tint_transform
        when PDF::Core::Reference
          tint_transform
        when Hash
          tint_transform.dup
        else
          raise ArgumentError,
            'tint transform must be a PDF function dictionary or reference'
        end
      end

      def build_tint_transform(tint_transform)
        return tint_transform if tint_transform.is_a?(PDF::Core::Reference)

        data = tint_transform.dup
        program = data.delete(:stream) || data.delete(:program)
        reference = ref!(data)
        reference << program if program
        reference
      end

      def create_defined_color_space(definition)
        function = build_tint_transform(definition.tint_transform)
        color_space_array =
          case definition.family
          when :Separation
            [
              :Separation,
              definition.names.first,
              definition.alternate_color_space,
              function,
            ]
          when :DeviceN
            [
              :DeviceN,
              definition.names,
              definition.alternate_color_space,
              function,
            ].tap do |array|
              array << definition.attributes if definition.attributes
            end
          end

        reference = ref!(color_space_array)
        resource_name = next_color_space_name

        DefinedColorSpace.new(
          definition.family,
          definition.names,
          definition.alternate_color_space,
          function,
          reference,
          resource_name,
          definition.attributes,
        )
      end

      def next_color_space_name
        @defined_color_space_count = (@defined_color_space_count || 0) + 1
        "PrawnCS#{@defined_color_space_count}".to_sym
      end

      def separation_color_spaces
        @separation_color_spaces ||= {}
      end

      def device_n_color_spaces
        @device_n_color_spaces ||= {}
      end

      def process_color(*color)
        if color.first.is_a?(DefinedColorSpace)
          color_space = color.first
          return color_space.color(*color[1..])
        end

        case color.size
        when 1
          color[0]
        when 4
          color
        else
          raise ArgumentError, 'wrong number of arguments supplied'
        end
      end

      def color_type(color)
        case color
        when String
          if /\A\h{6}\z/.match?(color)
            :RGB
          else
            raise ArgumentError, "Unknown type of color: #{color.inspect}"
          end
        when Array
          case color.length
          when 3
            :RGB
          when 4
            :CMYK
          else
            raise ArgumentError, "Unknown type of color: #{color.inspect}"
          end
        when SpecialColor
          :Special
        end
      end

      def normalize_color(color)
        case color_type(color)
        when :RGB
          r, g, b = hex2rgb(color)
          [r / 255.0, g / 255.0, b / 255.0]
        when :CMYK
          c, m, y, k = *color
          [c / 100.0, m / 100.0, y / 100.0, k / 100.0]
        when :Special
          color.tints
        end
      end

      def color_to_s(color)
        PDF::Core.real_params(normalize_color(color))
      end

      def color_space(color)
        case color_type(color)
        when :RGB
          :DeviceRGB
        when :CMYK
          :DeviceCMYK
        when :Special
          color.color_space
        end
      end

      BUILT_IN_COLOR_SPACES = %i[DeviceRGB DeviceCMYK Pattern].freeze

      def set_color_space(type, color_space)
        # don't set the same color space again
        revalidate = color_space_revalidation_required?(type)
        if !revalidate && current_color_space(type) == color_space &&
            !state.page.in_stamp_stream?
          return
        end

        set_current_color_space(color_space, type)
        clear_color_space_revalidation(type)

        unless color_space.is_a?(DefinedColorSpace) ||
            BUILT_IN_COLOR_SPACES.include?(color_space)
          raise ArgumentError, "unknown color space: '#{color_space}'"
        end

        operator =
          case type
          when :fill
            'cs'
          when :stroke
            'CS'
          else
            raise ArgumentError, "unknown type '#{type}'"
          end

        if color_space.is_a?(DefinedColorSpace)
          register_color_space(color_space)
          renderer.add_content("/#{color_space.resource_name} #{operator}")
        else
          renderer.add_content("/#{color_space} #{operator}")
        end
      end

      def register_color_space(color_space)
        color_spaces = page.resources[:ColorSpace] ||= {}
        color_spaces[color_space.resource_name] ||= color_space.to_pdf
      end

      def set_color(type, color, options = {})
        operator =
          case type
          when :fill
            'scn'
          when :stroke
            'SCN'
          else
            raise ArgumentError, "unknown type '#{type}'"
          end

        if options[:pattern]
          set_color_space(type, :Pattern)
          renderer.add_content("/#{color} #{operator}")
        else
          set_color_space(type, color_space(color))
          color = color_to_s(color)
          write_color(color, operator)
        end
      end

      def set_fill_color(color = nil)
        set_color(:fill, color || current_fill_color)
      end

      def set_stroke_color(color = nil)
        set_color(:stroke, color || current_stroke_color)
      end

      def update_colors
        set_fill_color
        set_stroke_color
      end

      def current_color_space(type)
        graphic_state.color_space[type]
      end

      def set_current_color_space(color_space, type)
        save_graphics_state if graphic_state.nil?
        graphic_state.color_space[type] = color_space
      end

      def mark_color_spaces_for_revalidation
        current_state = state.page.stack.current_state
        @color_spaces_requiring_revalidation =
          current_state ? current_state.color_space.keys : []
      end

      def color_space_revalidation_required?(type)
        @color_spaces_requiring_revalidation&.include?(type)
      end

      def clear_color_space_revalidation(type)
        @color_spaces_requiring_revalidation&.delete(type)
      end

      def current_fill_color
        graphic_state.fill_color
      end

      def current_fill_color=(color)
        graphic_state.fill_color = color
      end

      def current_stroke_color
        graphic_state.stroke_color
      end

      def current_stroke_color=(color)
        graphic_state.stroke_color = color
      end

      def write_color(color, operator)
        renderer.add_content("#{color} #{operator}")
      end
    end
  end
end
