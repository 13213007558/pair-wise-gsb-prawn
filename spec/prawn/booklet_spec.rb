# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Booklet::Planner do
  it 'imposes eight pages as two physical sheets' do
    planner = described_class.new(8, pages_per_signature: 8)

    expect(planner.blank_page_count).to eq(0)
    expect(planner.sheet_count).to eq(2)
    expect(planner.output_page_count).to eq(4)
    expect(side_pages(planner, 1, :front)).to eq([8, 1])
    expect(side_pages(planner, 1, :back)).to eq([2, 7])
    expect(side_pages(planner, 2, :front)).to eq([6, 3])
    expect(side_pages(planner, 2, :back)).to eq([4, 5])
  end

  it 'adds explicit blank pages instead of reusing existing pages' do
    planner = described_class.new(5, pages_per_signature: 8)

    expect(planner.logical_page_count).to eq(8)
    expect(planner.blank_page_count).to eq(3)
    expect(planner.pages.last(3).map(&:logical_number)).to eq([6, 7, 8])
    expect(planner.pages.last(3)).to all(be_blank)
    expect(side_pages(planner, 1, :front)).to eq([8, 1])
    expect(side_pages(planner, 1, :back)).to eq([2, 7])
  end

  it 'keeps signatures independent across two signatures' do
    planner = described_class.new(12, pages_per_signature: 8)

    expect(planner.signature_count).to eq(2)
    expect(planner.sheet_count).to eq(4)
    expect(planner.pages.last(4).map(&:logical_number)).to eq([13, 14, 15, 16])
    expect(planner.pages.last(4)).to all(be_blank)

    [
      [1, :front, [8, 1]], [1, :back, [2, 7]],
      [2, :front, [6, 3]], [2, :back, [4, 5]],
      [3, :front, [16, 9]], [3, :back, [10, 15]],
      [4, :front, [14, 11]], [4, :back, [12, 13]],
    ].each do |sheet, side, pages|
      expect(side_pages(planner, sheet, side)).to eq(pages)
    end
  end

  it 'reverses panel order for right binding' do
    planner = described_class.new(8, binding: :right)

    expect(side_pages(planner, 1, :front)).to eq([1, 8])
    expect(side_pages(planner, 1, :back)).to eq([7, 2])
  end

  it 'rotates back sides when flipping along the long edge' do
    planner = described_class.new(8, flip_edge: :long)

    expect(planner.sheets.first.front.map(&:rotation)).to eq([0, 0])
    expect(planner.sheets.first.back.map(&:rotation)).to eq([180, 180])
  end

  it 'keeps back sides upright when flipping along the short edge' do
    planner = described_class.new(8, flip_edge: :short)

    expect(planner.placements.map(&:rotation)).to all(eq(0))
  end

  it 'applies paper-thickness creep toward each fold' do
    planner = described_class.new(8, paper_thickness: 0.4)

    expect(creeps(planner, 1, :front)).to eq([{ x: 0.2, y: 0 },
                                             { x: -0.2, y: 0 }])
    expect(creeps(planner, 1, :back)).to eq([{ x: -0.2, y: 0 },
                                            { x: 0.2, y: 0 }])
    expect(creeps(planner, 2, :front)).to eq([{ x: 0.0, y: 0 },
                                             { x: -0.0, y: 0 }])
  end

  it 'rejects invalid signature sizes' do
    expect { described_class.new(8, pages_per_signature: 6) }
      .to raise_error(ArgumentError, /multiple of 4/)
  end

  def side_pages(planner, sheet_number, side)
    planner.sheets.fetch(sheet_number - 1).public_send(side)
      .map { |placement| placement.page.logical_number }
  end

  def creeps(planner, sheet_number, side)
    planner.sheets.fetch(sheet_number - 1).public_send(side).map(&:creep)
  end
end

describe Prawn::Document do
  describe '#booklet_plan' do
    it 'returns a serializable plan before rendering' do
      pdf = described_class.new(page_size: [100, 200], margin: 0)
      7.times { pdf.start_new_page }

      plan = pdf.booklet_plan(pages_per_signature: 8, paper_thickness: 0.4)

      expect(pdf.page_count).to eq(8)
      expect(plan[:source_page_count]).to eq(8)
      expect(plan[:blank_page_count]).to eq(0)
      expect(plan[:sheets].first[:front].map { |p| p[:logical_page] })
        .to eq([8, 1])
      expect(plan[:placements].first[:creep][:x]).to eq(0.2)
    end
  end

  describe '#render_booklet' do
    it 'renders eight logical pages on two duplex sheets' do
      pdf = booklet_pdf(8)

      plan = pdf.render_booklet(marks: false)
      output = PDF::Inspector::Page.analyze(pdf.render)

      expect(plan[:output_page_count]).to eq(4)
      expect(pdf.page_count).to eq(4)
      expect(booklet_text(pdf)).to eq(
        %w[81 27 63 45],
      )
      expect(output.pages.map { |page| page[:size] }.uniq).to eq([[200, 200]])
    end

    it 'renders explicit blanks without drawing another logical page' do
      pdf = booklet_pdf(5)

      pdf.render_booklet(marks: false)
      output = pdf.render

      expect(booklet_text(pdf)).to eq(['1', '2', '3', '45'])
      expect(output.scan('/BookletPage[678] Do')).to be_empty
      expect(output.scan(' re W n').size).to eq(5)
    end

    it 'uses the physical right and left panels for right binding' do
      pdf = booklet_pdf(8)
      pdf.render_booklet(marks: false, binding: :right)

      matrices = PDF::Inspector::Graphics::Matrix.analyze(pdf.render)
        .matrices.each_slice(2).to_a

      expect(matrices[0]).to eq([
        [1, 0, 0, 1, 0, 0], [1, 0, 0, 1, 100, 0],
      ])
      expect(matrices[1]).to eq([
        [1, 0, 0, 1, 0, 0], [1, 0, 0, 1, 100, 0],
      ])
    end

    it 'places pages on the expected panels and rotates long-edge backs' do
      pdf = booklet_pdf(8)
      pdf.render_booklet(marks: false, flip_edge: :long)

      matrices = PDF::Inspector::Graphics::Matrix.analyze(pdf.render)
        .matrices.each_slice(2).to_a

      expect(matrices[0]).to eq([
        [1, 0, 0, 1, 0, 0], [1, 0, 0, 1, 100, 0],
      ])
      expect(matrices[1]).to eq([
        [-1, 0, 0, -1, 100, 200], [-1, 0, 0, -1, 200, 200],
      ])
    end

    it 'applies numeric page scale while retaining the panel clip' do
      pdf = described_class.new(page_size: [80, 160], margin: 0)
      8.times do |index|
        pdf.draw_text((index + 1).to_s, at: [8, 140], size: 12)
        pdf.start_new_page unless index == 7
      end
      pdf.render_booklet(marks: false, fit: 1.25)

      matrix = PDF::Inspector::Graphics::Matrix.analyze(pdf.render)
        .matrices.first

      expect(matrix).to eq([1.25, 0, 0, 1.25, -10, -20])
    end

    it 'preserves creep compensation in the imposed page transforms' do
      pdf = booklet_pdf(8)
      pdf.render_booklet(marks: false, paper_thickness: 0.2)

      matrices = PDF::Inspector::Graphics::Matrix.analyze(pdf.render)
        .matrices.each_slice(2).to_a

      expect(matrices[0]).to eq([
        [1, 0, 0, 1, 0.1, 0], [1, 0, 0, 1, 99.9, 0],
      ])
      expect(matrices[1]).to eq([
        [1, 0, 0, 1, -0.1, 0], [1, 0, 0, 1, 100.1, 0],
      ])
    end

    it 'keeps each imposed page inside a panel clipping path' do
      pdf = booklet_pdf(8)
      pdf.render_booklet(marks: false)
      output = pdf.render

      expect(output.scan(/\bW\s+n/).size).to eq(8)
      expect(output).to include('0.0 0.0 100.0 200.0 re W n')
      expect(output).to include('100.0 0.0 100.0 200.0 re W n')
    end

    it 'draws crop and fold marks on every imposed sheet' do
      pdf = booklet_pdf(8)
      pdf.render_booklet
      lines = PDF::Inspector::Graphics::Line.analyze(pdf.render).points

      expect(lines).to include(
        [0.0, 6.0], [18.0, 6.0],
        [200.0, 6.0], [182.0, 6.0],
        [6.0, 0.0], [6.0, 18.0],
        [6.0, 200.0], [6.0, 182.0],
      )
      expect(lines).to include([82.0, 9.0], [118.0, 9.0])
      expect(lines).to include([82.0, 191.0], [118.0, 191.0])
    end

    it 'can be called twice without imposing the imposed pages again' do
      pdf = booklet_pdf(8)
      first_plan = pdf.render_booklet(marks: false)
      second_plan = pdf.render_booklet(marks: false)

      expect(pdf.page_count).to eq(4)
      expect(second_plan[:output_page_count]).to eq(first_plan[:output_page_count])
    end

    def booklet_pdf(page_count)
      described_class.new(page_size: [100, 200], margin: 0).tap do |pdf|
        page_count.times do |index|
          pdf.draw_text((index + 1).to_s, at: [10, 180], size: 12)
          pdf.start_new_page unless index == page_count - 1
        end
      end
    end

    def booklet_text(pdf)
      PDF::Reader.new(StringIO.new(pdf.render)).pages.map do |page|
        page.text.gsub(/\s+/, '')
      end
    end
  end
end
