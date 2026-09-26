#!/usr/bin/env python3
"""Builds a PDF whose fonts don't say what style they are, like many
InDesign books.

Fonts are embedded as Type0/Identity-H (as InDesign does) and renamed so
their names give nothing away ("Serif-S2" is the italic). Style can only
come from the font descriptors or from how the text is drawn. It also has
a word slanted into a fake italic, a word outlined into a fake bold, and a
bold section heading at the body size.

    pip install pymupdf
    python3 scripts/make_embedded_fonts_pdf.py Tests/Fixtures/embedded-fonts.pdf

Needs the Liberation Serif fonts (fonts-liberation on Debian/Ubuntu).
"""
import sys

import pymupdf

FONTS = "/usr/share/fonts/truetype/liberation/"
REGULAR, ITALIC, BOLD = "LiberationSerif-Regular.ttf", "LiberationSerif-Italic.ttf", "LiberationSerif-Bold.ttf"
NAMES = {REGULAR: ("fr", "Serif-S1"), ITALIC: ("fi", "Serif-S2"), BOLD: ("fb", "Serif-S3")}
SIZE, LEADING, LEFT, WIDTH = 10.5, 14, 60, 320

doc = pymupdf.open()
fonts = {f: pymupdf.Font(fontfile=FONTS + f) for f in NAMES}


def line(page, y, runs, x=LEFT):
    """runs: (text, font file, effect) with effect None, "slant" or "outline"."""
    for text, font, effect in runs:
        kwargs = {}
        if effect == "slant":
            kwargs["morph"] = (pymupdf.Point(x, y), pymupdf.Matrix(1, 0, -0.25, 1, 0, 0))
        if effect == "outline":
            kwargs["render_mode"] = 2
            kwargs["border_width"] = 0.03
        page.insert_text((x, y), text, fontsize=SIZE, fontname=NAMES[font][0], fontfile=FONTS + font, **kwargs)
        x += fonts[font].text_length(text, SIZE)


page = doc.new_page(width=420, height=595)
page.insert_text((LEFT, 90), "Chapter One", fontsize=20, fontname="fb", fontfile=FONTS + BOLD)
y = 140
body = [
    [("The first paragraph opens the chapter and has a word in ", REGULAR, None)],
    [("real ", REGULAR, None), ("italics", ITALIC, None), (" set in the italic font, and one in ", REGULAR, None)],
    [("slanted", REGULAR, "slant"), (" type made from the regular font, and one in ", REGULAR, None)],
    [("proper ", REGULAR, None), ("bold", BOLD, None), (" type, and one drawn ", REGULAR, None),
     ("outlined", REGULAR, "outline"), (" to look bold.", REGULAR, None)],
]
for runs in body:
    line(page, y, runs)
    y += LEADING
y += 12
line(page, y, [("A Section at Body Size", BOLD, None)])
y += LEADING + 2
for i, text in enumerate(["The section carries on with ordinary text after its heading, which is",
                          "set in bold at the same size as the words around it, with space above."]):
    line(page, y, [(text, REGULAR, None)], x=LEFT + (12 if i == 0 else 0))
    y += LEADING

doc.set_metadata({"title": "Embedded Fonts", "author": "Test"})
out = sys.argv[1]
doc.save(out, garbage=3, deflate=True)

# Rename the fonts so their names say nothing about their style, and give
# their descriptors the style information InDesign writes (PyMuPDF leaves it
# as regular): an italic angle and flag for the italic, a weight for the bold.
doc = pymupdf.open(out)
style = {"Regular": ("Serif-S1", None), "Italic": ("Serif-S2", "italic"), "Bold": ("Serif-S3", "bold")}
for xref in range(1, doc.xref_length()):
    for key in ("BaseFont", "FontName"):
        kind, value = doc.xref_get_key(xref, key)
        if kind != "name":
            continue
        for word, (alias, trait) in style.items():
            if word in value or (word == "Regular" and value.endswith("LiberationSerif")):
                doc.xref_set_key(xref, key, "/" + alias)
                if key == "FontName" and trait == "italic":
                    doc.xref_set_key(xref, "ItalicAngle", "-12")
                    doc.xref_set_key(xref, "Flags", "96")
                if key == "FontName" and trait == "bold":
                    doc.xref_set_key(xref, "FontWeight", "700")
                break
doc.save(out, incremental=True, encryption=0)
print("wrote", out)
