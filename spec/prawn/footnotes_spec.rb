# frozen_string_literal: true

require 'spec_helper'

describe Prawn::Footnotes do
  subject(:pdf) { Prawn::Document.new(margin: 40, page_size: 'A4') }

  def page_text(page)
    reader = PDF::Reader.new(StringIO.new(pdf.render))
    receiver = PageTextReceiver.new
    reader.page(page).walk(receiver)
    receiver.entries
  end

    class PageTextReceiver
      attr_reader :lines

    def initialize
      @lines = []
      @current = []
      @y = nil
    end

    def begin_text_object
      @current = []
    end

    def end_text_object
      @lines << @current
      @current = []
    end

    def move_text_position(_x, y)
      @y = y
    end

    def set_text_matrix_and_text_line_matrix(
      _a, _b, _c, _d, _x, y
    )
      @y = y
    end

    def show_text(string)
      @lines << [string, @y]
    end

    def entries
      @lines
    end

    def show_text_with_positioning(params)
      Array(params).each do |param|
        show_text(param) if param.is_a?(String)
      end
    end
  end

  it 'places several anchors and their notes on the same page' do
    pdf.footnote('first note') { |n| pdf.text("anchor #{n}") }
    pdf.footnote('second note') { |n| pdf.text("anchor #{n}") }

    expect(pdf.page_count).to eq(1)
    text = page_text(1)
    joined = text.map { |entry| entry.first.to_s }.join
    expect(joined).to include('anchor 1', 'anchor 2', '1. ', 'first note')
    expect(joined).to include('2. ', 'second note')
  end

  it 'keeps body text above every footnote chunk' do
    pdf.footnote('first note') { |n| pdf.text("anchor #{n}") }
    pdf.footnote('second note') { |n| pdf.text("anchor #{n}") }

    lines = page_text(1)
    body = lines.select { |_text, y| y && y > 90 }
    notes = lines.select { |_text, y| y && y <= 90 }

    expect(body.map { |_text, y| y }.min).to be > notes.map { |_text, y| y }.max
  end

  it 'splits a long footnote and keeps the anchor with its first chunk' do
    pdf.configure_footnotes(
      continuation_marker: ->(_number, state) {
        state == :continues ? ' (continued)' : '(continues) '
      },
    )
    long_note = ['word '] * 500
    pdf.move_cursor_to(200)
    pdf.footnote(long_note.join) { |n| pdf.text("anchor #{n}") }
    pdf.text('later body')

    expect(pdf.page_count).to eq(2)
    first_page = page_text(1)
    second_page = page_text(2)

    first_text = first_page.map { |entry| entry.first.to_s }.join
    second_text = second_page.map { |entry| entry.first.to_s }.join
    expect(first_text).to include('anchor 1', '1. ', '(continued)')
    expect(second_text).to include('(continues) ', 'later body', 'word')
  end

  it 'moves an anchor and its footnote together when they do not fit' do
    short_page = Prawn::Document.new(
      margin: 10,
      page_size: [200, 160],
    )
    short_page.configure_footnotes(separator: false, gap: 2)
    short_page.text('existing body ' * 20, size: 12)
    short_page.footnote('footnote text', size: 12, gap: 2) { |n|
      short_page.text("anchor #{n}", size: 12)
    }

    rendered = StringIO.new(short_page.render)
    pages = PDF::Inspector::Page.analyze(rendered.string).pages
    expect(pages.length).to eq(2)
    expect(pages[0][:strings]).not_to include('anchor 1')
    second_text = pages[1][:strings].join
    expect(second_text).to include('anchor 1', '1. ', 'footnote text')
  end

  it 'uses stable numbers after an unsuccessful layout attempt' do
    short_page = Prawn::Document.new(
      margin: 10,
      page_size: [200, 140],
    )
    short_page.configure_footnotes(separator: false, gap: 2)
    short_page.text('existing body ' * 10, size: 12)

    expect {
      short_page.footnote('footnote text', size: 12, gap: 2) { |n|
        short_page.text("anchor #{n}", size: 12)
      }
    }.not_to change { [short_page.page_count] }

    short_page.footnote('second') { |n| short_page.text("anchor #{n}") }
    strings = PDF::Inspector::Page.analyze(short_page.render).pages.flat_map {
      |page| page[:strings]
    }
    joined = strings.join
    expect(joined).to include('anchor 1', 'anchor 2', '1. ', '2. ')
    expect(joined.scan('1. ').size).to eq(1)
  end

  it 'raises a clear error when a footnote cannot fit on a page' do
    tiny_page = Prawn::Document.new(
      margin: 0,
      page_size: [100, 8],
    )
    tiny_page.configure_footnotes(separator: false, gap: 0)

    expect {
      tiny_page.footnote('a very long footnote that must wrap', size: 12, gap: 0, anchor_height: 0)
    }.to raise_error(
      Prawn::Errors::FootnoteCannotFit,
      /footnote 1.*(too large|cannot fit)/i,
    )
  end

  it 'does not leave footnote drawings after a failed attempt' do
    tiny_page = Prawn::Document.new(
      margin: 0,
      page_size: [100, 8],
    )
    tiny_page.configure_footnotes(separator: false, gap: 0)

    expect {
      tiny_page.footnote('a very long footnote that must wrap', size: 12, gap: 0, anchor_height: 0)
    }.to raise_error(Prawn::Errors::FootnoteCannotFit)

    tiny_page.go_to_page(1)
    expect(PDF::Inspector::Page.analyze(tiny_page.render).pages.first[:strings])
      .to be_empty
  end

  it 'accepts caller-provided formatted continuation text' do
    pdf.configure_footnotes(
      continuation_marker: ->(_number, state) {
        if state == :continues
          [{ text: ' cont.', styles: [:italic] }]
        else
          []
        end
      },
      separator: false,
      gap: 0,
    )
    pdf.move_cursor_to(180)
    pdf.footnote((['word '] * 500).join, size: 10)

    strings = PDF::Inspector::Page.analyze(pdf.render).pages.map {
      |page| page[:strings]
    }
    expect(strings.first.join).to include('cont.')
  end
end
