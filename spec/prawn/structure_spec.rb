# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

describe Prawn::Structure do
  let(:document) do
    Prawn::Document.new(tagged: true, margin: 36)
  end

  let(:output) { document.render }
  let(:objects) do
    PDF::Reader::ObjectHash.new(StringIO.new(output))
  end
  let(:catalog) { objects.deref(objects.trailer[:Root]) }
  let(:tree_root) { objects[catalog[:StructTreeRoot]] }
  let(:root_element) { objects[tree_root[:K]] }

  def element(ref)
    objects[ref]
  end

  def content_for(mcr)
    page_ref = mcr[:Pg]
    page = objects[page_ref]
    stream = objects.deref(page[:Contents])
    streams =
      if stream.is_a?(Array)
        stream.map { |ref| objects[ref].unfiltered_data }
      else
        [stream.unfiltered_data]
      end

    stack = []
    values = []
    streams.join.each_line do |line|
      if line.include?('BDC')
        mcid = line[/\/MCID\s+(\d+)/, 1]&.to_i
        stack << mcid
      elsif line.include?('EMC')
        stack.pop
      elsif stack.include?(mcr[:MCID])
        line.scan(/<([0-9a-fA-F]+)>/) do |(hex)|
          values << [hex].pack('H*')
        end
      end
    end
    values.join
  end

  def element_text(ref)
    struct = element(ref)
    Array(struct[:K]).map do |kid|
      if kid.is_a?(PDF::Reader::Reference)
        element_text(kid)
      else
        content_for(kid)
      end
    end.join
  end

  def type_of(kid)
    if kid.is_a?(PDF::Reader::Reference)
      objects[kid][:S]
    else
      :MCR
    end
  end

  it 'writes catalog, role, parent-tree, and nested structure metadata' do
    document.tag(:H1) { document.text('Title') }
    document.tag(:L) do
      document.tag(:LI) do
        document.tag(:Lbl) { document.text('1.') }
        document.tag(:LBody) { document.text('First item') }
      end
    end

    expect(catalog[:MarkInfo]).to eq(Marked: true)
    expect(tree_root[:ParentTreeNextKey]).to eq(1)
    expect(root_element[:S]).to eq(:Document)
    expect(root_element[:K].map { |kid| type_of(kid) }).to eq(%i[H1 L])

    list = objects[root_element[:K].last]
    list_item = objects[list[:K].first]
    expect(list_item[:P]).to eq(root_element[:K].last)
    expect(list_item[:K].map { |kid| type_of(kid) }).to eq(%i[Lbl LBody])

    page = objects[objects.page_references.first]
    expect(page[:StructParents]).to eq(0)
    parent_tree = objects[tree_root[:ParentTree]]
    parents = parent_tree[:Nums]
    expect(parents[0]).to eq(0)
    expect(parents[1]).to all(be_a(PDF::Reader::Reference))
  end

  it 'keeps one logical element across pages and maps every page back to it' do
    paragraph = nil
    document.repeat(:all, dynamic: true) do
      document.artifact(:header, attached: :Top) do
        document.draw_text('Running header', at: [36, 740])
      end
    end
    document.tag(:H1) { document.text('Title') }
    document.tag(:P) do |tag|
      paragraph = tag
      document.text('cross page paragraph ' * 300)
    end

    expect(PDF::Reader.new(StringIO.new(output)).page_count).to eq(2)

    paragraph_ref = root_element[:K].last
    paragraph_struct = objects[paragraph_ref]
    expect(paragraph_struct[:S]).to eq(:P)
    expect(paragraph_struct[:K].length).to eq(2)
    expect(paragraph_struct[:K].map { |mcr| mcr[:Pg] }).to eq(
      objects.page_references,
    )

    parent_tree = objects[tree_root[:ParentTree]]
    Array(parent_tree[:Nums]).each_slice(2) do |_page_index, parents|
      expect(parents).to include(paragraph_ref)
    end
  end

  it 'reads nested structure in the author-declared order' do
    document.tag(:H1) { document.text('Title') }
    document.tag(:P) do
      document.text('cross page paragraph ' * 300)
    end
    document.tag(:L) do
      document.tag(:LI) do
        document.tag(:Lbl) { document.text('1.') }
        document.tag(:LBody) { document.text('First item') }
      end
    end

    ordered = root_element[:K].map { |ref| element_text(ref) }
    expect(ordered.map { |text| text[0, 12] }).to eq(
      ['Title', 'cross page p', '1.First item'],
    )
    expect(ordered[1]).to start_with('cross page paragraph')
    expect(ordered[1]).to end_with('paragraph')
  end

  it 'marks repeated header drawing as artifact content rather than body tags' do
    document.repeat(:all, dynamic: true) do
      document.artifact(:header, attached: :Top) do
        document.draw_text('Running header', at: [36, 740])
      end
    end
    document.tag(:H1) { document.text('Title') }

    objects.page_references.each do |page_ref|
      page = objects[page_ref]
      stream = objects.deref(page[:Contents])
      content =
        if stream.is_a?(Array)
          stream.map { |ref| objects[ref].unfiltered_data }.join
        else
          stream.unfiltered_data
        end
      expect(content).to include(
        '/Artifact << /Type /Pagination /Subtype /Header /Attached [/Top] >> BDC',
      )
      expect(content.scan('/Artifact <<').length).to eq(1)
    end

    parent_tree = objects[tree_root[:ParentTree]]
    all_parents = parent_tree[:Nums].each_slice(2).map(&:last).flatten
    expect(all_parents.map { |ref| objects[ref][:S] }).to eq([:H1])
  end

  it 'marks a static repeated header stamp as an artifact' do
    document.repeat(:all) do
      document.artifact(:header, attached: :Top) do
        document.draw_text('Running header', at: [36, 740])
      end
    end
    document.start_new_page
    document.tag(:H1) { document.text('Title') }

    form_stream = nil
    objects.page_references.each do |page_ref|
      page = objects[page_ref]
      resources = objects.deref(page[:Resources])
      xobjects = objects.deref(resources[:XObject])
      xobjects.each do |_name, xobject|
        xobject = objects[xobject] if xobject.is_a?(PDF::Reader::Reference)
        next unless xobject.hash[:Subtype] == :Form

        form_stream = xobject.unfiltered_data
      end
    end

    expect(form_stream).to include(
      '/Artifact << /Type /Pagination /Subtype /Header /Attached [/Top] >> BDC',
    )
    expect(form_stream).not_to include('/H1')
    expect(form_stream).not_to include('/MCID')
  end

  it 'creates structure lazily and reports untagged documents normally' do
    pdf = Prawn::Document.new
    result = pdf.render
    reader = PDF::Reader::ObjectHash.new(StringIO.new(result))
    root = reader.deref(reader.trailer[:Root])
    expect(root).not_to have_key(:StructTreeRoot)
    expect(root).not_to have_key(:MarkInfo)
  end
end
