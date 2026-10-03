# frozen_string_literal: true

require_relative '../../spec_helper'

describe Prawn::Text::Formatted::VerticalWrap do
  let(:font_path) { File.join(Prawn::DATADIR, 'fonts', 'gkai00mp.ttf') }

  def render_vertical(text, **options)
    size = options.delete(:size) || 10
    document_options = { margin: 0 }
    if options.key?(:compress)
      document_options[:compress] = options.delete(:compress)
    end
    pdf = Prawn::Document.new(document_options)
    pdf.font(font_path, size: size)
    output = pdf.text_box(
      text,
      {
        at: [50, 700],
        width: 80,
        height: 100,
        writing_mode: :vertical_rl,
        leading: 5,
      }.merge(options),
    )
    [pdf.render, output]
  end

  it 'rejects fonts without vertical metrics tables' do
    pdf = create_pdf
    expect do
      pdf.text_box('abc', writing_mode: :vertical_rl)
    end.to raise_error(Prawn::Errors::UnsupportedVerticalFont)
  end

  it 'places CJK glyphs with vertical metrics and rotates Latin sideways' do
    rendered, leftover = render_vertical('中A', compress: false)

    expect(leftover).to eq('')
    expect(rendered).to include('/Encoding /Identity-V')
    expect(rendered).to include('<03d4> Tj')
    expect(rendered).to include('1 0 0 1 125.0 701.21094 Tm')
    expect(rendered).to include('0 1 -1 0 125.0 687.5 Tm')
    expect(rendered).to include('<0041> Tj')
    expect { PDF::Reader.new(StringIO.new(rendered)).pages.first.text }.not_to raise_error
  end

  it 'advances columns right to left and preserves overflow text' do
    rendered, leftover = render_vertical(
      '中中中中中中',
      width: 25,
      height: 25,
      compress: false,
    )

    expect(leftover).to eq('中中')
    expect(rendered).to include('1 0 0 1 70.0 701.21094 Tm')
    expect(rendered).to include('1 0 0 1 55.0 701.21094 Tm')
    expect(rendered).not_to include('1 0 0 1 40.0 701.21094 Tm')
  end

  it 'uses an explicit newline as a column break' do
    rendered, _leftover = render_vertical("中\n中", width: 25, compress: false)

    expect(rendered).to include('1 0 0 1 70.0 701.21094 Tm')
    expect(rendered).to include('1 0 0 1 55.0 701.21094 Tm')
  end

  it 'uses vertical fragment bounds for link annotations' do
    pdf = Prawn::Document.new(margin: 0, compress: false)
    pdf.font(font_path, size: 10)
    pdf.formatted_text_box(
      [{ text: '中', link: 'https://example.test' }],
      at: [50, 700],
      width: 80,
      height: 100,
      writing_mode: :vertical_rl,
    )

    rendered = pdf.render
    expect(rendered).to include('/URI (https://example.test)')
    expect(rendered).to include('/Rect [125 701.21094 135 711.21094]')
  end
end

describe Prawn::Fonts::VerticalData do
  it 'applies GSUB vrt2 single substitutions before vertical metrics' do
    coverage = [1, 1, 421].pack('n3')
    single = [2, 8, 1, 0].pack('n4') + coverage
    lookup = [1, 0, 1, 8].pack('n4') + single
    feature = [0x00000100, 1, 0].pack('Nn2')
    feature_list = [1, 'vrt2', 8].pack('na4n') + feature
    langsys = [0x00000100, 0xFFFF, 0].pack('Nn2')
    script = [8, 4].pack('n2') + langsys
    script_list = [1, 'DFLT', 8].pack('na4n') + script
    gsub = [0x00010000].pack('N') +
      [10, 10 + script_list.bytesize, 10 + script_list.bytesize + feature_list.bytesize].pack('n3') +
      script_list + feature_list + lookup

    vhea = [0x00010000].pack('N') +
      [900, -120, 0, 1000].pack('s>3n') +
      ([0] * 7).pack('n*') + [1].pack('n')
    vmtx = [1000, 0].pack('n s>')
    font = double(
      directory: double(tables: {
        'vhea' => { offset: 0, length: vhea.bytesize },
        'vmtx' => { offset: vhea.bytesize, length: vmtx.bytesize },
        'GSUB' => { offset: vhea.bytesize + vmtx.bytesize, length: gsub.bytesize },
      }),
      contents: StringIO.new(vhea + vmtx + gsub),
      maximum_profile: double(num_glyphs: 1),
    )

    data = described_class.new(font)

    expect(data.vertical_origin_y(0)).to eq(900)
    expect(data.substitute(421)).to eq(0)
    expect(data.advance_height(0)).to eq(1000)
    expect(data.vertical_origin_y(0)).to eq(900)
  end
end
