# frozen_string_literal: true

module Prawn
  # Logical structure and tagged PDF support.
  module Structure
    # Marked-content artifact, such as a running page header.
    class ArtifactMarker
      # @return [Symbol, nil]
      attr_reader :type

      # @return [Symbol, nil]
      attr_reader :attached

      # @return [Array<Numeric>, nil]
      attr_reader :bbox

      # @param type [Symbol, nil]
      # @param attached [Symbol, nil]
      # @param bbox [Array<Numeric>, nil]
      def initialize(type = nil, attached: nil, bbox: nil)
        @type = type
        @attached = attached
        @bbox = bbox
        @open = false
      end

      # Open this artifact in the current content stream.
      #
      # @param document [Prawn::Document]
      # @return [void]
      def open(document)
        return if @open

        document.renderer.add_content("#{properties} BDC")
        @open = true
      end

      # Close this artifact in the current content stream.
      #
      # @param document [Prawn::Document]
      # @return [void]
      def close(document)
        return unless @open

        document.renderer.add_content('EMC')
        @open = false
      end

      # @return [Boolean]
      def open?
        @open
      end

      private

      def properties
        dictionary = []
        dictionary << "/Type /#{artifact_type}" if artifact_type
        dictionary << "/Subtype /#{artifact_subtype}" if artifact_subtype
        if attached
          values = Array(attached).map { |edge| "/#{edge}" }.join(' ')
          dictionary << "/Attached [#{values}]"
        end
        if bbox
          dictionary << "/BBox [#{bbox.map { |n| PDF::Core.real(n) }.join(' ')}]"
        end

        if dictionary.empty?
          '/Artifact << >>'
        else
          "/Artifact << #{dictionary.join(' ')} >>"
        end
      end

      def artifact_type
        case type
        when :header, :footer then :Pagination
        when :background then :Background
        when nil then nil
        else type
        end
      end

      def artifact_subtype
        case type
        when :header then :Header
        when :footer then :Footer
        else nil
        end
      end

    end

    # Builds the PDF logical structure tree and marked-content sequences.
    class TaggedStructure
      # @param document [Prawn::Document]
      def initialize(document)
        @document = document
        @active = []
        @page_mcids = Hash.new { |hash, key| hash[key] = [] }
        @next_mcid = Hash.new(0)
        @finalized = false
        @armed = true
        @writing_marker = false

        @parent_tree = document.ref!(Nums: [])
        @root = document.ref!(
          Type: :StructElem,
          S: :Document,
          P: nil,
          K: [],
        )
        @tree_root = document.ref!(
          Type: :StructTreeRoot,
          K: @root,
          ParentTree: @parent_tree,
        )
        @root.data[:P] = @tree_root

        catalog = document.state.store.root.data
        catalog[:StructTreeRoot] = @tree_root
        catalog[:MarkInfo] = { Marked: true }
        document.renderer.min_version(1.7)
        document.renderer.before_render { finalize! }
        document.renderer.define_singleton_method(:add_content) do |content|
          document.structure.content_will_be_added!(content)
          super(content)
        end
      end

      # Group the supplied block as a logical structure element.
      #
      # @param type [Symbol] Standard structure type, such as `:H1` or `:P`.
      # @param title [String, nil]
      # @param lang [String, nil]
      # @param alt [String, nil]
      # @param actual_text [String, nil]
      # @param expanded_text [String, nil]
      # @yield Content belonging to the element.
      # @return [Element]
      def tag(
        type,
        title: nil,
        lang: nil,
        alt: nil,
        actual_text: nil,
        expanded_text: nil,
        &block
      )
        element = begin_tag(
          type,
          title: title,
          lang: lang,
          alt: alt,
          actual_text: actual_text,
          expanded_text: expanded_text,
        )
        begin
          block&.call(element)
        ensure
          end_tag(element)
        end
        element
      end

      # Begin a logical structure element without requiring a block.
      #
      # @return [Prawn::Structure::TaggedStructure::Element]
      def begin_tag(
        type,
        title: nil,
        lang: nil,
        alt: nil,
        actual_text: nil,
        expanded_text: nil
      )
        raise ArgumentError, 'structure type is required' if type.nil?
        raise ArgumentError, 'cannot tag a stamp XObject' if
          @document.state.page.in_stamp_stream?
        if @active.any? { |marker| marker.is_a?(ArtifactMarker) }
          raise ArgumentError, 'cannot tag artifact content'
        end

        close_open_markers

        data = {
          Type: :StructElem,
          S: type,
          P: parent_reference,
          K: [],
        }
        data[:T] = title if title
        data[:Lang] = lang if lang
        data[:Alt] = alt if alt
        data[:ActualText] = actual_text if actual_text
        data[:E] = expanded_text if expanded_text

        element = Element.new(
          @document.ref!(data),
          type,
        )
        parent_kids << element.reference
        @active.push(element)
        element
      end

      # End a structure element opened by {#begin_tag}.
      #
      # @param element [Element, nil]
      # @return [void]
      def end_tag(element = nil)
        element ||= @active.last
        unless element.is_a?(Element) && @active.last.equal?(element)
          raise ArgumentError, 'structure tags must be closed in order'
        end

        close_open_markers
        @active.pop
      end

      # Mark a block as a page artifact rather than document content.
      #
      # @return [ArtifactMarker]
      def artifact(type = nil, attached: nil, bbox: nil, &block)
        marker = begin_artifact(type, attached: attached, bbox: bbox)
        begin
          block&.call(marker)
        ensure
          end_artifact(marker)
        end
        marker
      end

      # Begin an artifact without requiring a block.
      #
      # @return [ArtifactMarker]
      def begin_artifact(type = nil, attached: nil, bbox: nil)
        close_open_markers
        marker = ArtifactMarker.new(type, attached: attached, bbox: bbox)
        @active.push(marker)
        marker
      end

      # End an artifact opened by {#begin_artifact}.
      #
      # @param marker [ArtifactMarker, nil]
      # @return [void]
      def end_artifact(marker = nil)
        marker ||= @active.last
        unless marker.is_a?(ArtifactMarker) && @active.last.equal?(marker)
          raise ArgumentError, 'artifacts must be closed in order'
        end

        marker.close(@document)
        @active.pop
      end

      # Temporarily close marked ranges before a page change.
      #
      # @return [void]
      def suspend_on_page_change
        @armed = false
        close_open_markers
      end

      # Arm logical markers for the new page. The first drawing command opens
      # the innermost marker lazily, keeping page-creation callbacks out of the
      # logical structure.
      #
      # @return [void]
      def resume_on_page_change
        @armed = true
      end

      # Called immediately before any page or stamp content is written.
      #
      # @return [void]
      def content_will_be_added!(content = nil)
        return unless @armed && !@writing_marker
        return unless drawing_content?(content)
        in_stamp_stream = @document.state.page.in_stamp_stream?
        marker = @active.last
        return if in_stamp_stream && !marker.is_a?(ArtifactMarker)

        @writing_marker = true
        begin
          case marker
          when Element
            open_element(marker) unless marker.open?
          when ArtifactMarker
            marker.open(@document) unless marker.open?
          end
        ensure
          @writing_marker = false
        end
      end

      # Treat state-only operators (for example color changes issued before
      # any drawing) as content-neutral so they do not allocate an empty MCID.
      def drawing_content?(content)
        content.to_s.match?(
          /\b(?:BT|Tj|TJ|'|"|m|l|c|v|y|h|re|S|s|f|f\*|B|B\*|b|b\*|sh|Do)\b/,
        )
      end

      # Write StructParents and the page-to-structure parent tree.
      #
      # @return [void]
      def finalize!
        return if @finalized

        finish_unclosed
        @document.state.pages.each_with_index do |page, index|
          page.dictionary.data[:StructParents] = index
        end
        @parent_tree.data[:Nums] =
          @document.state.pages.each_with_index.map do |_page, index|
            [index, @page_mcids[index]]
          end.flatten(1)
        @tree_root.data[:ParentTreeNextKey] = @document.state.pages.length
        @finalized = true
      end

      # A logical structure element.
      class Element
        # @return [PDF::Core::Reference]
        attr_reader :reference

        # @return [Symbol]
        attr_reader :type

        # @param reference [PDF::Core::Reference]
        # @param type [Symbol]
        def initialize(reference, type)
          @reference = reference
          @type = type
        end

        # Open a marked-content sequence for this element.
        #
        # @param document [Prawn::Document]
        # @param mcid [Integer]
        # @return [void]
        def open(document, mcid)
          @open = true
          document.renderer
            .add_content("/#{type} << /MCID #{mcid} >> BDC")
        end

        # Close the current marked-content sequence.
        #
        # @param document [Prawn::Document]
        # @return [void]
        def close(document)
          return unless @open

          document.renderer.add_content('EMC')
          @open = false
        end

        # @return [Boolean]
        def open?
          @open == true
        end

        # @return [Array]
        def kids
          reference.data[:K]
        end
      end

      private

      def parent_reference
        @active.last.is_a?(Element) ? @active.last.reference : @root
      end

      def parent_kids
        parent_reference.data[:K]
      end

      def close_open_markers
        @active.reverse_each do |marker|
          case marker
          when Element
            marker.close(@document)
          when ArtifactMarker
            marker.close(@document)
          end
        end
      end

      def open_element(element)
        page = @document.state.page
        page_index = @document.page_number - 1
        mcid = @next_mcid[page_index]
        @next_mcid[page_index] += 1
        mcr = {
          Type: :MCR,
          Pg: page.dictionary,
          MCID: mcid,
        }
        element.kids << mcr
        @page_mcids[page_index][mcid] = element.reference
        element.open(@document, mcid)
      end

      def finish_unclosed
        while (marker = @active.last)
          case marker
          when Element
            end_tag(marker)
          when ArtifactMarker
            end_artifact(marker)
          end
        end
      end
    end

    # Structure methods mixed into Prawn documents.
    module API
      # Tagged PDF structure for this document.
      #
      # @return [TaggedStructure]
      def structure
        @tagged_structure ||= TaggedStructure.new(self)
      end

      # Create a logical structure element around a block.
      #
      # @see TaggedStructure#tag
      def tag(type, **options, &block)
        structure.tag(type, **options, &block)
      end

      # Begin a logical structure element.
      #
      # @see TaggedStructure#begin_tag
      def begin_tag(type, **options)
        structure.begin_tag(type, **options)
      end

      # End a logical structure element.
      #
      # @see TaggedStructure#end_tag
      def end_tag(element = nil)
        structure.end_tag(element)
      end

      # Mark a block as an artifact.
      #
      # @see TaggedStructure#artifact
      def artifact(type = nil, **options, &block)
        structure.artifact(type, **options, &block)
      end

      # Begin an artifact.
      #
      # @see TaggedStructure#begin_artifact
      def begin_artifact(type = nil, **options)
        structure.begin_artifact(type, **options)
      end

      # End an artifact.
      #
      # @see TaggedStructure#end_artifact
      def end_artifact(marker = nil)
        structure.end_artifact(marker)
      end
    end
  end

  class Document
    include Prawn::Structure::API
  end
end
