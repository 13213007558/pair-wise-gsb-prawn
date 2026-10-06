# frozen_string_literal: true

module Prawn
  module Graphics
    module Color
      SpotColor = Struct.new(
        :kind,
        :names,
        :alternate_color_space,
        :tint_transform,
        :resource_name,
        :values,
        keyword_init: true,
      ) do
        def initialize_copy(other)
          super
          self.names = other.names.dup
          self.values = other.values.dup
        end

        def with_values(new_values)
          values = Array(new_values).flatten

          valid_values = values.all? do |value|
            value.is_a?(Numeric) && (0..1).cover?(value)
          end
          unless values.length == names.length && valid_values
            raise ArgumentError,
              "expected #{names.length} spot-color values between 0 and 1"
          end

          dup.tap { |color| color.values = values }
        end

        def definition
          colorants =
            case kind
            when :Separation
              names.first
            when :DeviceN
              names
            end

          [kind, colorants, alternate_color_space, tint_transform]
        end
      end

      SPOT_ALTERNATE_COLOR_SPACES = {
        DeviceRGB: 3,
        DeviceCMYK: 4,
        DeviceGray: 1,
      }.freeze

      public

      def separation_color(name, *arguments, **options)
        alternate_color_space = arguments[0]
        tint_transform = arguments[1] ||
          options[:function] || pdf_function_options(options)
        create_spot_color(
          :Separation,
          [name],
          options[:alternate] || alternate_color_space,
          tint_transform,
          options[:values] || (options[:tint] ? [options[:tint]] : nil),
        )
      end

      alias spot_color separation_color
      alias separation separation_color

      def device_n_color(names, *arguments, **options)
        alternate_color_space = arguments[0]
        tint_transform = arguments[1] ||
          options[:function] || pdf_function_options(options)
        create_spot_color(
          :DeviceN,
          names,
          options[:alternate] || alternate_color_space,
          tint_transform,
          options[:values],
        )
      end

      alias device_n device_n_color

      def pdf_function_options(options)
        function_keys = options.keys - %i[alternate function values tint]
        return if function_keys.empty?

        options.slice(*function_keys)
      end

      def overprint(fill: true, stroke: true)
        save_graphics_state if block_given?
        renderer.add_content("/#{overprint_dictionary_name(fill, stroke)} gs")

        if block_given?
          yield
          restore_graphics_state
        end
      end
      private :pdf_function_options

      private

      def create_spot_color(
        kind, names, alternate_color_space, tint_transform, values
      )
        names = Array(names).map(&:to_sym)
        validate_spot_names(kind, names)

        alternate_color_space = alternate_color_space&.to_sym
        components = SPOT_ALTERNATE_COLOR_SPACES[alternate_color_space]
        unless components
          raise ArgumentError,
            "unknown alternate color space: #{alternate_color_space.inspect}"
        end

        function_reference =
          build_spot_tint_transform(kind, names, components, tint_transform)
        values ||= Array.new(names.length, 1.0)
        values = Array(values).flatten
        validate_numeric_array(values, names.length, :values, (0..1))

        SpotColor.new(
          kind: kind,
          names: names,
          alternate_color_space: alternate_color_space,
          tint_transform: function_reference,
          resource_name: "SpotCS#{next_spot_color_space_id}",
          values: values,
        )
      end

      def validate_spot_names(kind, names)
        if names.empty? || names.any?(&:empty?)
          raise ArgumentError, 'spot-color channel names cannot be empty'
        end
        if names.length != names.uniq.length
          raise ArgumentError, 'spot-color channel names must be unique'
        end
        return unless kind == :Separation && names.length != 1

        raise ArgumentError, 'Separation colors must declare one channel'
      end

      def build_spot_tint_transform(kind, names, components, tint_transform)
        unless tint_transform.is_a?(Hash)
          raise ArgumentError,
            "unsupported spot-color tint transform: #{tint_transform.inspect}"
        end

        function = tint_transform.transform_keys(&:to_sym)
        function_type = function[:FunctionType] || function[:function_type]
        unless [2, 4].include?(function_type)
          raise ArgumentError,
            "unsupported spot-color tint function: #{function_type.inspect}"
        end

        known_keys = case function_type
        when 2
          %i[FunctionType function_type Domain C0 C1 N Range]
        when 4
          %i[FunctionType function_type Domain Range Program program]
        end

        if (function.keys - known_keys).any?
          raise ArgumentError,
            "unsupported spot-color tint transform: #{tint_transform.inspect}"
        end

        case function_type
        when 2
          build_type2_tint_transform(kind, components, function)
        when 4
          build_type4_tint_transform(kind, names, components, function)
        end
      end

      def build_type2_tint_transform(kind, components, function)
        unless kind == :Separation
          raise ArgumentError,
            'DeviceN tint transforms must use a Type 4 function'
        end

        domain = function.fetch(:Domain, [0.0, 1.0])
        c0 = function.fetch(:C0, Array.new(components, 0.0))
        c1 = function.fetch(:C1, Array.new(components, 1.0))
        exponent = function[:N]

        validate_numeric_array(domain, 2, :Domain)
        unless domain == [0, 1] || domain == [0.0, 1.0]
          raise ArgumentError, "invalid spot-color Domain: #{domain.inspect}"
        end
        validate_numeric_array(c0, components, :C0, (0..1))
        validate_numeric_array(c1, components, :C1, (0..1))
        validate_optional_function_range(function[:Range], components)
        unless exponent.is_a?(Numeric) && exponent > 0
          raise ArgumentError, 'spot-color tint transform N must be positive'
        end

        ref!(
          FunctionType: 2,
          Domain: domain,
          C0: c0,
          C1: c1,
          N: exponent,
        )
      end

      def build_type4_tint_transform(kind, names, components, function)
        program = function[:Program] || function[:program]
        unless program.is_a?(String)
          raise ArgumentError,
            'Type 4 spot-color tint transforms require a String Program'
        end

        domain_length = kind == :Separation ? 2 : names.length * 2
        domain = function.fetch(:Domain, [0.0, 1.0] * names.length)
        validate_numeric_array(domain, domain_length, :Domain)
        domain.each_slice(2) do |lower, upper|
          unless lower.zero? && upper == 1
            raise ArgumentError, "invalid spot-color Domain: #{domain.inspect}"
          end
        end
        validate_optional_function_range(function[:Range], components)

        reference = ref!(FunctionType: 4, Domain: domain)
        reference << program
        reference
      end

      def validate_optional_function_range(range, components)
        return if range.nil?

        validate_numeric_array(range, components * 2, :Range)
        range.each_slice(2) do |lower, upper|
          unless lower <= upper
            raise ArgumentError, "invalid spot-color Range: #{range.inspect}"
          end
        end
      end

      def validate_numeric_array(array, length, name, range = nil)
        valid = array.is_a?(Array) && array.length == length &&
          array.all? { |value| value.is_a?(Numeric) }
        valid &&= array.all? { |value| range.cover?(value) } if range
        return if valid

        raise ArgumentError, "invalid spot-color #{name}: #{array.inspect}"
      end

      def next_spot_color_space_id
        @spot_color_space_count = @spot_color_space_count.to_i + 1
      end

      def page_color_spaces
        resources = state.page.resources
        if resources[:ColorSpace]
          deref(resources[:ColorSpace])
        else
          resources[:ColorSpace] = {}
        end
      end

      def register_spot_color(color)
        page_color_spaces[color.resource_name.to_sym] ||= color.definition
      end

      def overprint_dictionary_registry
        @overprint_dictionary_registry ||= {}
      end

      def overprint_dictionary_name(fill, stroke)
        key = [fill, stroke]
        registry = overprint_dictionary_registry

        unless registry.key?(key)
          count = registry.length + 1
          registry[key] = {
            name: "OP#{count}",
            object: ref!(
              Type: :ExtGState,
              op: fill,
              OP: stroke,
              OPM: 1,
            ),
          }
        end

        entry = registry[key]
        state.page.ext_gstates[entry[:name].to_sym] = entry[:object]
        entry[:name]
      end
    end
  end
end
