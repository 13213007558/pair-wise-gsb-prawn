# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Document::Booklet do
  def build_pdf(page_count, page_size: [200, 300], crop_box: nil)
    Prawn::Document.new(page_size: page_size, margin: 0).tap do |pdf|
      page_count.times do |index|
        pdf.text "Page #{index + 1}"
        if crop_box
          pdf.state.page.dictionary.data[:CropBox] = crop_box
          pdf.state.page.dictionary.data[:TrimBox] = crop_box
        end
        pdf.start_new_page unless index == page_count - 1
      end
    end
  end

  def page_numbers(side)
    side.placements.map(&:source_page)
  end

  def rendered_pages(pdf, **options)
    PDF::Reader.new(StringIO.new(pdf.render_booklet(**options))).pages
  end

  describe Prawn::Document::Booklet::Plan do
    it 'imposes an eight-page signature in front and back order' do
      plan = described_class.new(
        page_count: 8,
        pages_per_signature: 8,
        binding: :left,
        flip: :short,
        paper_thickness: 0,
        scale: 1,
        marks: true,
      )

      expect(plan.blank_page_count).to eq(0)
      expect(plan.signature_count).to eq(1)
      expect(plan.sheets.map { |sheet|
        [page_numbers(sheet.front), page_numbers(sheet.back)]
      }).to eq([
        [[8, 1], [2, 7]],
        [[6, 3], [4, 5]],
      ])
    end

    it 'uses explicit nil pages instead of reusing content for blanks' do
      plan = described_class.new(
        page_count: 6,
        pages_per_signature: 8,
        binding: :left,
        flip: :short,
        paper_thickness: 0,
        scale: 1,
        marks: false,
      )

      expect(plan.blank_page_count).to eq(2)
      expect(plan.sheets.map { |sheet|
        [page_numbers(sheet.front), page_numbers(sheet.back)]
      }).to eq([
        [[nil, 1], [2, nil]],
        [[6, 3], [4, 5]],
      ])
    end

    it 'keeps signatures independent when content crosses two signatures' do
      plan = described_class.new(
        page_count: 16,
        pages_per_signature: 8,
        binding: :left,
        flip: :short,
        paper_thickness: 0,
        scale: 1,
        marks: false,
      )

      expect(plan.signature_count).to eq(2)
      expect(plan.sheets.map(&:number)).to eq([1, 1, 2, 2])
      expect(plan.sheets.map { |sheet|
        [page_numbers(sheet.front), page_numbers(sheet.back)]
      }).to eq([
        [[8, 1], [2, 7]],
        [[6, 3], [4, 5]],
        [[16, 9], [10, 15]],
        [[14, 11], [12, 13]],
      ])
    end

    it 'supports right binding and both duplex flip sides' do
      right_plan = described_class.new(
        page_count: 8,
        pages_per_signature: 8,
        binding: :right,
        flip: :short,
        paper_thickness: 0,
        scale: 1,
        marks: false,
      )
      long_flip_plan = described_class.new(
        page_count: 8,
        pages_per_signature: 8,
        binding: :left,
        flip: :long,
        paper_thickness: 0,
        scale: 1,
        marks: false,
      )

      expect(page_numbers(right_plan.sheets.first.front)).to eq([1, 8])
      expect(page_numbers(right_plan.sheets.first.back)).to eq([7, 2])
      expect(long_flip_plan.sheets.first.front.placements.map(&:rotation))
        .to eq([0, 0])
      expect(long_flip_plan.sheets.first.back.placements.map(&:rotation))
        .to eq([180, 180])
    end

    it 'computes decreasing creep from paper thickness' do
      plan = described_class.new(
        page_count: 8,
        pages_per_signature: 8,
        binding: :left,
        flip: :short,
        paper_thickness: 2,
        scale: 1,
        marks: false,
      )

      expect(plan.sheets.first.front.placements.map(&:creep)).to eq([-1, 1])
      expect(plan.sheets.last.front.placements.map(&:creep)).to eq([0, 0])
    end

    it 'rejects signatures that are not positive multiples of four' do
      expect do
        described_class.new(
          page_count: 1,
          pages_per_signature: 6,
          binding: :left,
          flip: :short,
          paper_thickness: 0,
          scale: 1,
          marks: false,
        )
      end.to raise_error(ArgumentError, /multiple of 4/)
    end
  end

  describe '#render_booklet' do
    it 'creates one landscape sheet for every two imposed pages' do
      pdf = build_pdf(8)
      pages = rendered_pages(pdf, pages_per_signature: 8)

      expect(pages.size).to eq(4)
      expect(pages.map { |page| page.attributes[:MediaBox] }).to all(
        eq([0, 0, 436, 336]),
      )
    end

    it 'omits form xobjects for explicit blank pages' do
      pdf = build_pdf(6)
      pages = rendered_pages(pdf, pages_per_signature: 8)

      expect(pages[0].raw_content.scan(%r{/BP(\d+) Do})).to eq([['1']])
      expect(pages[1].raw_content.scan(%r{/BP(\d+) Do})).to eq([['2']])
      expect(pages[2].raw_content.scan(%r{/BP(\d+) Do})).to eq(
        [%w[6], %w[3]],
      )
    end

    it 'preserves source crop boxes while clipping and placing content' do
      pdf = build_pdf(8, crop_box: [10, 20, 190, 280])
      pages = rendered_pages(
        pdf,
        pages_per_signature: 8,
        flip: :long,
        mark_margin: 18,
      )

      expect(pages[0].attributes[:MediaBox]).to eq([0, 0, 396, 296])
      expect(pages[0].raw_content).to include(
        '198.0 18.0 180.0 260.0 re W n',
        '1.0 0.0 0.0 1.0 198.0 18.0 cm',
      )
      expect(pages[1].raw_content).to include(
        '18.0 18.0 180.0 260.0 re W n',
        '-1.0 0.0 0.0 -1.0 198.0 278.0 cm',
      )
    end

    it 'draws crop and fold marks outside the imposed page rectangles' do
      pdf = build_pdf(8)
      page = rendered_pages(pdf, pages_per_signature: 8).first

      expect(page.raw_content).to include(
        '218.0 18.0 m',
        '218.0 318.0 l S',
        '18.0 18.0 m',
        '9.0 18.0 l S',
        '418.0 318.0 m',
        '418.0 327.0 l S',
      )
    end

    it 'scales content inside a retained clipping rectangle' do
      pdf = build_pdf(8)
      pages = rendered_pages(
        pdf,
        pages_per_signature: 8,
        scale: 0.5,
        marks: false,
      )

      expect(pages.first.attributes[:MediaBox]).to eq([0, 0, 400, 300])
      expect(pages.first.raw_content).to include(
        '50.0 75.0 100.0 150.0 re W n',
        '0.5 0.0 0.0 0.5 50.0 75.0 cm',
      )
    end

    it 'rotates long-edge backs and applies outward creep' do
      pdf = build_pdf(8)
      pages = rendered_pages(
        pdf,
        pages_per_signature: 8,
        flip: :long,
        paper_thickness: 2,
        marks: false,
      )

      expect(pages[1].raw_content).to include(
        '-1.0 0.0 200.0 300.0 re W n',
        '-1.0 0.0 0.0 -1.0 199.0 300.0 cm',
        '201.0 0.0 200.0 300.0 re W n',
        '-1.0 0.0 0.0 -1.0 401.0 300.0 cm',
      )
    end

    it 'yields the plan before rendering' do
      pdf = build_pdf(8)
      yielded = nil

      pdf.render_booklet(pages_per_signature: 8) do |plan|
        yielded = page_numbers(plan.sheets.first.front)
      end

      expect(yielded).to eq([8, 1])
    end
  end
end
