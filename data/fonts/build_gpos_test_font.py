#!/usr/bin/env python3
"""Builds GPOSTest.ttf, a tiny test font with a GPOS table.

The font contains a handful of glyphs and a GPOS table exercising:
  * PairPos format 1 (glyph pair "A V")
  * PairPos format 2 (class pair [T] x [o])
  * MarkToBase attachment (combining acute/dot above onto base letters)
  * MarkToMark attachment (combining dot above stacking on combining acute)
  * a language-system-specific kern feature (latn/ENG)

All metrics are in a 1000 units/em grid so expected values are easy to
compute by hand. Regenerate with:

    python3 data/fonts/build_gpos_test_font.py
"""

from fontTools.fontBuilder import FontBuilder
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.pens.ttGlyphPen import TTGlyphPen

UPM = 1000

GLYPHS = [
    (".notdef", 0),
    ("A", 600),
    ("V", 620),
    ("T", 560),
    ("o", 500),
    ("acutecomb", 240),
    ("dotabovecomb", 220),
    ("space", 250),
]

CMAP = {
    0x41: "A",
    0x56: "V",
    0x54: "T",
    0x6F: "o",
    0x0301: "acutecomb",
    0x0307: "dotabovecomb",
    0x20: "space",
}

FEATURES = """
languagesystem DFLT dflt;
languagesystem latn dflt;
languagesystem latn ENG;

lookup KernPair {
    pos A V -80;
} KernPair;

lookup KernClass {
    @first = [T];
    @second = [o];
    pos @first @second -40;
} KernClass;

lookup KernLang {
    pos A V -200;
} KernLang;

markClass acutecomb <anchor 120 480> @MC1;
markClass dotabovecomb <anchor 110 470> @MC1;
markClass dotabovecomb <anchor 110 520> @MC2;

feature kern {
    script DFLT;
    language dflt;
    lookup KernPair;
    lookup KernClass;
    script latn;
    language dflt;
    lookup KernPair;
    lookup KernClass;
    script latn;
    language ENG exclude_dflt;
    lookup KernLang;
} kern;

feature mark {
    pos base A <anchor 300 700> mark @MC1;
    pos base V <anchor 310 700> mark @MC1;
    pos base T <anchor 280 700> mark @MC1;
    pos base o <anchor 250 500> mark @MC1;
} mark;

feature mkmk {
    pos mark acutecomb <anchor 120 760> mark @MC2;
} mkmk;
"""


def rectangle_glyph(pen, x0, y0, x1, y1):
    pen.moveTo((x0, y0))
    pen.lineTo((x1, y0))
    pen.lineTo((x1, y1))
    pen.lineTo((x0, y1))
    pen.closePath()


def build(path):
    fb = FontBuilder(UPM, isTTF=True)
    glyph_order = [name for name, _ in GLYPHS]
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap(CMAP)

    glyphs = {}
    metrics = {}
    for name, advance in GLYPHS:
        pen = TTGlyphPen(None)
        if name not in (".notdef", "space"):
            rectangle_glyph(pen, 50, 0, min(advance - 50, 450), 700)
        glyphs[name] = pen.glyph()
        metrics[name] = (advance, 50)
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({
        "familyName": "GPOSTest",
        "styleName": "Regular",
        "uniqueFontIdentifier": "GPOSTest Regular",
        "fullName": "GPOSTest Regular",
        "psName": "GPOSTest-Regular",
        "version": "1.0",
    })
    fb.setupOS2(
        sTypoAscender=800,
        sTypoDescender=-200,
        usWinAscent=800,
        usWinDescent=200,
    )
    fb.setupPost()
    fb.setupDummyDSIG()
    fb.setupMaxp()

    addOpenTypeFeaturesFromString(fb.font, FEATURES)
    fb.save(path)
    print("wrote", path)


if __name__ == "__main__":
    import os
    build(os.path.join(os.path.dirname(os.path.abspath(__file__)), "GPOSTest.ttf"))
