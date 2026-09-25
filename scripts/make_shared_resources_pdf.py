#!/usr/bin/env python3
"""Builds a PDF where every page and every form XObject share one resource
dictionary, the way InDesign and other layout tools often write books.

Walking that dictionary naively from each form that points back to it grows
as the cube of its size; this fixture guards against that hang.

    python3 scripts/make_shared_resources_pdf.py Tests/Fixtures/shared-resources.pdf
"""
import sys

FORMS = 400
PAGES = 3
TEXT = ("This page shares its resources with every other page and with {forms} "
        "small graphics that point back at the same list.")

objects = {}  # number -> bytes


def add(number, body):
    objects[number] = body if isinstance(body, bytes) else body.encode("latin-1")


# 1 catalog, 2 pages tree, 3 shared resources, 4 font, 10.. forms, 1000.. pages/content
form_ids = [10 + i for i in range(FORMS)]
xobjects = " ".join(f"/Fm{i} {n} 0 R" for i, n in enumerate(form_ids))
add(3, f"<< /Font << /F1 4 0 R >> /XObject << {xobjects} >> >>")
add(4, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
for n in form_ids:
    stream = b"0 0 1 rg 0 0 2 2 re f"
    add(n, b"<< /Type /XObject /Subtype /Form /BBox [0 0 2 2] /Resources 3 0 R /Length %d >>\nstream\n%s\nendstream"
        % (len(stream), stream))

page_ids = []
for p in range(PAGES):
    page_id, content_id = 1000 + 2 * p, 1001 + 2 * p
    page_ids.append(page_id)
    lines = [TEXT.format(forms=FORMS)[i:i + 60] for i in range(0, len(TEXT.format(forms=FORMS)), 60)]
    ops = ["BT /F1 11 Tf 14 TL 72 720 Td"] + [f"({line}) '" for line in lines] + ["ET", "q /Fm0 Do Q"]
    stream = "\n".join(ops).encode("latin-1")
    add(content_id, b"<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream))
    add(page_id, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources 3 0 R /Contents {content_id} 0 R >>")

add(2, f"<< /Type /Pages /Kids [{' '.join(f'{n} 0 R' for n in page_ids)}] /Count {PAGES} >>")
add(1, "<< /Type /Catalog /Pages 2 0 R >>")

out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
offsets = {}
for number in sorted(objects):
    offsets[number] = len(out)
    out += b"%d 0 obj\n" % number + objects[number] + b"\nendobj\n"
size = max(objects) + 1
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % size
for number in range(1, size):
    out += (b"%010d 00000 n \n" % offsets[number]) if number in offsets else b"0000000000 65535 f \n"
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (size, xref)
open(sys.argv[1], "wb").write(out)
