# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

describe Prawn::Document do
  it 'leaves ordinary documents without a structure tree' do
    pdf = described_class.new
    pdf.text('Ordinary')

    reader = PDF::Reader.new(StringIO.new(pdf.render))
    root = reader.objects.deref_hash(reader.objects.trailer[:Root])

    expect(root).not_to have_key(:StructTreeRoot)
    expect(root).not_to have_key(:MarkInfo)
  end

  it 'does not add body structure for artifact-only content' do
    pdf = described_class.new
    pdf.artifact(:footer) { pdf.text('Page furniture') }

    reader = PDF::Reader.new(StringIO.new(pdf.render))
    root = reader.objects.deref_hash(reader.objects.trailer[:Root])

    expect(root).not_to have_key(:StructTreeRoot)
    expect(root).not_to have_key(:MarkInfo)
    expect(reader.pages.first.raw_content).to include('/Artifact')
  end

  MarkedContentCollector = Class.new do
    attr_reader :events

    def initialize(_reader)
      @events = []
      @stack = []
    end

    def begin_marked_content_with_pl(tag, properties)
      entry = { tag: tag }
      if properties.is_a?(Hash) && properties[:Type] == :Artifact
        entry[:artifact] = true
        entry[:properties] = properties
      end
      entry[:mcid] = properties[:MCID] if properties.is_a?(Hash)
      @events << [:begin, entry]
      @stack << entry
    end

    def end_marked_content
      @events << [:end, @stack.pop]
    end

    def show_text(string)
      return if @stack.empty?

      current = @stack.last
      current[:text] = +'' unless current[:text]
      current[:text] << string
    end

    def show_text_with_positioning(items)
      items.each { |item| show_text(item) if item.is_a?(String) }
    end

    def collect(page)
      page.walk(self)
      self
    end
  end

  def marked_content(reader, page)
    MarkedContentCollector.new(reader).collect(page).events
  end

  def struct_tree(reader)
    root = reader.objects.deref_hash(reader.objects.trailer[:Root])
    tree = reader.objects.deref_hash(root[:StructTreeRoot])
    [root, tree]
  end

  def element(reader, reference)
    reader.objects.deref_hash(reference)
  end

  def element_type(reader, reference)
    element(reader, reference)[:S]
  end

  def element_text(reader, reference, page_entries)
    unless reference.is_a?(PDF::Reader::Reference)
      reference = reference.reference
      reference = PDF::Reader::Reference.new(reference.identifier, 0)
    end
    dict = element(reader, reference)
    Array(dict[:K]).grep(PDF::Reader::Reference).flat_map do |child|
      raw_child = reader.objects.deref(child)
      next [] unless raw_child.is_a?(Hash)
      child_dict = raw_child
      if child_dict[:Type] == :MCR
        page_number = child_dict[:Pg].id
        mcid = child_dict[:MCID]
        Array(page_entries[[page_number, mcid]])
      else
        if child_dict[:Type] == :StructElem
          element_text(reader, child, page_entries)
        else
          []
        end
      end
    end
  end

  it 'builds a nested structure tree with explicit cross-page reading order' do
    pdf = described_class.new(page_size: [300, 180], margin: 20)
    pdf.repeat(:all, dynamic: true) do
      pdf.artifact(:header) { pdf.draw_text('Running header', at: [20, 158]) }
    end

    heading = pdf.structure_element(:H1, title: 'Report')
    paragraph = pdf.structure_element(:P, title: 'Cross-page paragraph')
    list = pdf.structure_element(:L)
    item = pdf.structure_element(:LI, parent: list)
    label = pdf.structure_element(:Lbl, parent: item)
    body = pdf.structure_element(:LBody, parent: item)
    pdf.reading_order(heading, paragraph, list)

    pdf.tag_element(heading) { pdf.text('Title first in reading order') }
    pdf.tag_element(list) do
      pdf.tag_element(label) { pdf.text('1.') }
      pdf.tag_element(body) { pdf.text('List item after paragraph') }
    end
    pdf.tag_element(paragraph) do
      pdf.text('Paragraph continues ' + ('across the page ' * 40))
    end

    output = pdf.render
    file = Tempfile.new(['two-page-tagged', '.pdf'])
    file.binmode
    file.write(output)
    file.close
    reader = PDF::Reader.new(file.path)
    expect(File.binread(file.path)).to start_with('%PDF-')
    expect(reader.page_count).to eq(2)

    root, tree = struct_tree(reader)
    expect(root[:MarkInfo]).to eq(Marked: true)
    expect(tree[:Type]).to eq(:StructTreeRoot)

    order = Array(tree[:K]).map { |reference| element_type(reader, reference) }
    expect(order).to eq(%i[H1 P L])

    list_dict = element(reader, tree[:K][2])
    list_children = Array(list_dict[:K]).map { |reference| element(reader, reference) }
    expect(list_children.select { |child| child[:Type] == :StructElem }.map { |child| child[:S] })
      .to eq(%i[LI])
    item_dict = list_children.find { |child| child[:Type] == :StructElem }
    item_children = Array(item_dict[:K]).map { |reference| element(reader, reference) }
    expect(item_children.select { |child| child[:Type] == :StructElem }.map { |child| child[:S] })
      .to eq(%i[Lbl LBody])

    parent_tree = reader.objects.deref_hash(tree[:ParentTree])
    nums = Array(parent_tree[:Nums])
    page_entries = {}
    page_by_dictionary = {}
    marked_by_page = {}

    reader.pages.each do |page|
      page_dict = page.page_object
      key = page_dict[:StructParents]
      expect(key).to be_a(Integer)
      array_ref = nums[nums.index(key) + 1]
      parents = reader.objects.deref(array_ref)
      expect(parents).to be_a(Array)

      entries = marked_content(reader, page)
      marked_by_page[page.number] = entries
      page_ref = reader.objects.page_references[page.number - 1]
      page_by_dictionary[page_ref.id] = page.number
      parents.each_with_index do |parent, mcid|
        next unless parent

        starts = entries.select { |event, entry| event == :begin && entry[:mcid] }
        matching = starts.any? { |_event, entry| entry[:mcid] == mcid }
        expect(matching).to be(true)
        parent_dict = element(reader, parent)
        expect(parent_dict[:Type]).to eq(:StructElem)
        child_refs = Array(parent_dict[:K]).grep(PDF::Reader::Reference)
        referenced_here = child_refs.any? do |child|
          child_dict = reader.objects.deref_hash(child)
          child_dict[:Type] == :MCR &&
            child_dict[:Pg].id == page_ref.id &&
            child_dict[:MCID] == mcid
        end
        expect(referenced_here).to be(true)
      end

      starts = entries.select { |event, entry| event == :begin && entry[:mcid] }
      starts.each do |_event, entry|
        page_entries[[page_ref.id, entry[:mcid]]] = entry[:text]
      end
    end

    paragraph_text = element_text(reader, paragraph, page_entries).join
    expect(paragraph_text)
      .to include('across the page')
    paragraph_dict = element(reader, tree[:K][1])
    pages = Array(paragraph_dict[:K]).map do |reference|
      mcr = reader.objects.deref_hash(reference)
      page_by_dictionary[mcr[:Pg].id]
    end
    expect(pages).to eq([1, 2])

    artifact_events = marked_by_page.values.flatten(1).select do |event, entry|
      event == :begin && entry&.dig(:artifact)
    end
    expect(artifact_events.size).to eq(2)
    expect(artifact_events.map { |_event, entry| entry[:text] }.compact)
      .to eq(['Running header', 'Running header'])
    expect(artifact_events.map { |_event, entry| entry[:properties] })
      .to all(
        include(
          Type: :Artifact,
          Subtype: :Pagination,
          Attached: :Top,
        ),
      )

    logical_order = Array(tree[:K]).flat_map do |reference|
      element_text(reader, reference, page_entries)
    end.join(' ')
    expect(logical_order).to start_with('Title first in reading order')
    expect(logical_order.index('Paragraph continues'))
      .to be < logical_order.index('List item after paragraph')
    expect(reader.pages.first.text)
      .to match(/List item after paragraph.*Paragraph continues/m)
    expect(logical_order).not_to include('Running header')
  ensure
    file&.unlink
  end

  it 'keeps a static repeated header stamp outside active content' do
    pdf = described_class.new
    pdf.repeat(:all) do
      pdf.artifact(:header) { pdf.draw_text('Static header', at: [10, 780]) }
    end
    pdf.paragraph { pdf.text('Body') }

    reader = PDF::Reader.new(StringIO.new(pdf.render))

    reader.pages.each do |page|
      expect(page.raw_content).to include('/Stamp1 Do')
      stamp_line = page.raw_content.lines.find { |line| line.include?('/Stamp1 Do') }
      preceding = page.raw_content[0...page.raw_content.index(stamp_line)]
      expect(preceding.scan('/P << /MCID').size)
        .to eq(preceding.scan('EMC').size)
    end
  end
end
