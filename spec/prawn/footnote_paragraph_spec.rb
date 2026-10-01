# frozen_string_literal: true

require 'spec_helper'

describe 'footnotes inside flowing text' do
  it 'moves the anchor and first footnote chunk with a paragraph break' do
    pdf = Prawn::Document.new(
      margin: 10,
      page_size: [250, 180],
    )
    pdf.configure_footnotes(separator: false, gap: 2)
    pdf.text('top ' * 70, size: 12)

    pdf.footnote(
      'short footnote',
      size: 9,
      gap: 2,
    ) do |number|
      pdf.formatted_text(
        [
          { text: 'before break ' * 10, size: 12 },
          pdf.footnote_reference(number, size: 7),
          { text: ' after break', size: 12 },
        ],
        final_gap: false,
      )
    end

    pages = PDF::Inspector::Page.analyze(pdf.render).pages
    expect(pages.length).to be >= 2
    expect(pages[0][:strings].join).not_to include('after break')
    expect(pages[0][:strings].join).not_to include('(continued)')
    second_page = pages[1][:strings].join
    expect(second_page).to include('after break', '1.')
    expect(second_page).to include('short footnote')
  end
end
