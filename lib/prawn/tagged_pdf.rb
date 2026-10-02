# frozen_string_literal: true

module Prawn
  class Document
    module TaggedPdf
      class Artifact
        attr_reader :type, :attributes

        def initialize(type, attributes)
          @type = type
          @attributes = attributes
        end

        def operator
          properties = ['/Type /Artifact']
          unless type == :artifact
            properties << "/Subtype /#{artifact_name(type)}"
          end
          if attributes[:attached]
            edge = artifact_name(attributes.fetch(:attached))
            properties << "/Attached /#{edge}"
          end
          "/Artifact <<#{properties.join(' ')}>> BDC"
        end

        private

        def artifact_name(value)
          value.to_s.split('_').map(&:capitalize).join
        end
      end

      class StructureElement
        attr_reader :reference, :type, :children, :content_references

        def initialize(document, type, parent, title: nil, lang: nil,
                       alt: nil, actual_text: nil)
          @type = type
          @children = []
          @content_references = []
          @reference = document.ref!(
            Type: :StructElem, S: type, P: parent,
          )
          @reference.data[:T] = title if title
          @reference.data[:Lang] = lang if lang
          @reference.data[:Alt] = alt if alt
          @reference.data[:ActualText] = actual_text if actual_text
        end

        def child(element)
          @children << element
          element
        end

        def reading_order(*elements)
          elements.flatten.each { |element| child(element) }
        end

        def sync
          if @content_references.any? || @children.any?
            content = @content_references + @children
            @reference.data[:K] = content.map do |child|
              child.respond_to?(:reference) ? child.reference : child
            end
          end
        end

        def add_content_reference(reference)
          @content_references << reference
        end
      end

      class StructureRoot
        attr_reader :reference, :elements

        def initialize(document)
          @document = document
          @elements = []
          @reference = document.ref!(Type: :StructTreeRoot)
        end

        def child(element)
          @elements << element unless @elements.include?(element)
          element
        end

        def reading_order(*elements)
          @elements = elements.flatten
        end

        def sync
          @reference.data[:K] = @elements.map(&:reference) if @elements.any?
        end

        def reading_order_for(element, children)
          element.reading_order(*children)
        end
      end

      class MarkedContentSpan
        attr_reader :element

        def initialize(document, element, page_state)
          @document = document
          @element = element
          @page_state = page_state
          @mcid = page_state.next_mcid
          @mcr = document.ref!(Type: :MCR, Pg: page_state.page.dictionary)
          @mcr.data[:MCID] = @mcid
          page_state.parent_tree[@mcid] = @element.reference
          @element.add_content_reference(@mcr)
          @open = false
        end

        def page?(page_state)
          @page_state.equal?(page_state)
        end

        def open?
          @open
        end

        def open
          unless @open
            @document.begin_marked_content("/P << /MCID #{@mcid} >> BDC")
            @open = true
          end
          self
        end

        def close
          if @open
            @document.end_marked_content
            @open = false
          end
          self
        end
      end

      class ArtifactSpan
        def initialize(document, artifact)
          @document = document
          @artifact = artifact
          @open = false
        end

        def open
          unless @open
            @document.begin_marked_content(@artifact.operator)
            @open = true
          end
          self
        end

        def close
          if @open
            @document.end_marked_content
            @open = false
          end
          self
        end
      end

      class TagManager
        def initialize(document)
          @document = document
          @structure_root = StructureRoot.new(document)
          @active_elements = []
          @active_spans = []
          @active_artifact = nil
          @pages = {}
          @next_struct_parent = 0
          @finalized = false
        end

        attr_reader :structure_root

        def page_change_requested
          @document.send(:flush_pending_marked_content)
          close_open_content
        end

        def page_started(page)
          @pages[page.dictionary] ||=
            PageState.new(page, allocate_struct_parent)
        end

        def content_starting(content)
          unless page.in_stamp_stream? || !@pages.key?(page.dictionary) ||
              @stamp_invocation
            ensure_open_content
          end
          content
        end

        def stamp_invocation
          close_open_content
          @stamp_invocation = true
          yield
        ensure
          @stamp_invocation = false
        end

        def structure_element(type, **options, &block)
          element = create_element(type, **options)
          block ? with_element(element, &block) : element
        end

        def tagged(type, **options, &block)
          raise ArgumentError, 'tagged requires a block' unless block

          with_element(create_element(type, **options), &block)
        end

        def tag_element(element, &block)
          raise ArgumentError, 'tag_element requires a block' unless block

          with_element(element, &block)
        end

        def artifact(type = nil, **options, &block)
          type, options = normalize_artifact(type, options)
          marked = Artifact.new(type || :artifact, options)
          return marked unless block

          close_open_content
          @active_artifact = ArtifactSpan.new(@document, marked).open
          begin
            block.call(marked)
          ensure
            @active_artifact.close
            @active_artifact = nil
          end
          marked
        end

        def reading_order(*elements)
          @structure_root.reading_order(*elements)
        end

        def finalize
          return if @finalized

          close_open_content
          @finalized = true
          return unless tagged?

          sync_elements
          build_parent_tree
          catalog[:StructTreeRoot] = @structure_root.reference
          catalog[:MarkInfo] = { Marked: true }
          @document.renderer.min_version(1.4)
        end

        private

        def with_element(element)
          @active_elements << element
          begin
            yield element
          ensure
            unless @active_elements.pop.equal?(element)
              raise 'unbalanced tagged structure'
            end
            close_span_for(element)
          end
          element
        end

        def create_element(type, parent: nil, title: nil, lang: nil, alt: nil,
                          actual_text: nil)
          parent ||= @active_elements.last || @structure_root
          element = StructureElement.new(
            @document,
            type,
            parent.reference,
            title: title,
            lang: lang,
            alt: alt,
            actual_text: actual_text,
          )
          parent.child(element)
          element
        end

        def ensure_open_content
          return if @active_artifact
          return if @active_elements.empty?

          state = current_page_state
          @active_elements.each do |element|
            already_has_span = @active_spans.any? do |span|
              span.element.equal?(element) && span.page?(state)
            end
            unless already_has_span
              @active_spans << MarkedContentSpan.new(@document, element, state)
            end
          end
          @active_spans.select { |span| span.page?(state) }.each(&:open)
        end

        def close_open_content
          @active_spans.select(&:open?).each(&:close)
          @active_artifact&.close
        end

        def close_span_for(element)
          spans = @active_spans.select do |candidate|
            candidate.element.equal?(element)
          end
          spans.select(&:open?).each(&:close)
          @active_spans.reject! do |candidate|
            candidate.element.equal?(element)
          end
        end

        def current_page_state
          @pages.fetch(page.dictionary)
        end

        def allocate_struct_parent
          value = @next_struct_parent
          @next_struct_parent += 1
          value
        end

        def build_parent_tree
          pairs = []
          active_pages = @document.state.pages.map(&:dictionary)
          active_page_states = active_pages.map do |page|
            @pages.fetch(page)
          end
          active_page_states.each do |page_state|
            array = @document.ref!(page_state.parent_tree)
            page_state.page.dictionary.data[:StructParents] =
              page_state.struct_parent
            pairs << [page_state.struct_parent, array]
          end
          nums = pairs.sort_by(&:first).flat_map { |key, value| [key, value] }
          parent_tree = @document.ref!(Nums: nums)
          @structure_root.reference.data[:ParentTree] = parent_tree
          @structure_root.reference.data[:ParentTreeNextKey] =
            @next_struct_parent
        end

        def sync_elements
          all_elements.each(&:sync)
          @structure_root.sync
        end

        def all_elements
          walk_elements(@structure_root.elements)
        end

        def walk_elements(elements)
          elements.flat_map do |element|
            [element] + walk_elements(element.children.grep(StructureElement))
          end
        end

        def tagged?
          all_elements.any?
        end

        def catalog
          @document.state.store.root.data
        end

        def page
          @document.state.page
        end

        def normalize_artifact(type, options)
          case type
          when :header
            [:pagination, options.merge(attached: options.fetch(:attached, :top))]
          when :footer
            [:pagination, options.merge(attached: options.fetch(:attached, :bottom))]
          else
            [type, options]
          end
        end

        class PageState
          attr_reader :page, :struct_parent

          def initialize(page, struct_parent)
            @page = page
            @struct_parent = struct_parent
            @parent_tree = []
            @next_mcid = 0
          end

          def next_mcid
            value = @next_mcid
            @next_mcid += 1
            value
          end

          def parent_tree
            @parent_tree
          end
        end
      end

      private_constant :TagManager, :MarkedContentSpan, :ArtifactSpan, :Artifact

      # Root of the PDF logical-structure tree.
      # @return [StructureRoot]
      def structure_tree
        tag_manager.structure_root
      end

      # Declare a structure element; optional block marks its content.
      # @param type [Symbol] PDF structure type, such as `:H1`, `:P` or `:L`.
      # @option options :parent [StructureElement, StructureRoot] parent.
      # @option options :title [String] human-readable title.
      # @option options :lang [String] BCP 47 language.
      # @option options :alt [String] alternate description.
      # @option options :actual_text [String] replacement text.
      # @return [StructureElement]
      def structure_element(type, **options, &block)
        tag_manager.structure_element(type, **options, &block)
      end

      alias tag structure_element
      alias structure_tag structure_element

      # Create a structure element and mark all drawing in the block.
      # Content in the block can continue across page breaks.
      # @return [StructureElement]
      def tagged(type, **options, &block)
        tag_manager.tagged(type, **options, &block)
      end

      # Mark content with an already declared structure element.
      # @return [StructureElement]
      def tag_element(element, &block)
        tag_manager.tag_element(element, &block)
      end

      # Mark block content as an artifact, such as a header or footer.
      # @return [Artifact]
      def artifact(type = nil, **options, &block)
        tag_manager.artifact(type, **options, &block)
      end

      # Set root reading order independently from drawing order.
      # @return [Array<StructureElement>]
      def reading_order(*elements)
        tag_manager.reading_order(*elements)
      end

      # Set an element's child reading order independently from drawing order.
      def structure_reading_order(element, *children)
        structure_tree.reading_order_for(element, children)
      end

      # Mark a heading at the given level.
      # @return [StructureElement]
      def heading(level = 1, **options, &block)
        tagged("H#{level}".to_sym, **options, &block)
      end

      # Mark a paragraph.
      # @return [StructureElement]
      def paragraph(**options, &block)
        tagged(:P, **options, &block)
      end

      # Mark a list.
      # @return [StructureElement]
      def list(**options, &block)
        tagged(:L, **options, &block)
      end

      # Mark a list item.
      # @return [StructureElement]
      def list_item(**options, &block)
        tagged(:LI, **options, &block)
      end

      # Mark a list item label.
      # @return [StructureElement]
      def list_label(**options, &block)
        tagged(:Lbl, **options, &block)
      end

      # Mark a list item body.
      # @return [StructureElement]
      def list_body(**options, &block)
        tagged(:LBody, **options, &block)
      end

      # @api private
      def add_content(content)
        tag_manager.content_starting(content)
        flush_pending_marked_content
        add_raw_content(content)
      end

      # @api private
      def add_raw_content(content)
        renderer.send(:tagged_content_without_hook, content)
      end

      # @api private
      def begin_marked_content(operator)
        renderer_pending_content << operator
      end

      # @api private
      def end_marked_content
        flush_pending_marked_content
        add_raw_content('EMC')
      end

      private

      def tag_manager
        @tag_manager ||= TagManager.new(self)
      end

      def renderer_pending_content
        renderer.instance_variable_get(:@tagged_pending_content) ||
          renderer.instance_variable_set(:@tagged_pending_content, [])
      end

      def flush_pending_marked_content
        while (operator = renderer_pending_content.shift)
          renderer.send(:tagged_write_content, operator)
        end
      end

      def initialize_tagged_pdf_renderer
        renderer.singleton_class.class_eval do
          alias_method :tagged_content_without_hook, :add_content
          define_method(:add_content) do |content|
            document = state.pages.first&.document
            if document
              document.add_content(content)
            else
              tagged_content_without_hook(content)
            end
          end
          define_method(:tagged_write_content) do |content|
            tagged_content_without_hook(content)
          end
        end
      end
    end
  end
end
