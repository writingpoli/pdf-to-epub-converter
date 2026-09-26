# PDF to EPUB

A small Mac app that turns a PDF book into a reflowable EPUB for Apple Books.

A PDF is a set of fixed pages. In Books that means pinching and scrolling, and your font, size and theme settings don't apply. This app rebuilds the book's text as flowing chapters, so Books can lay it out on any screen the way it does for books from the Book Store.

## What it does

- **Rejoins paragraphs** from the separate lines a PDF stores, including paragraphs that carry on over a page turn.
- **Rejoins words split at a line end.** “conversa-/tions” comes back as “conversations”, while a real compound like “waistcoat-pocket” keeps its hyphen.
- **Removes page furniture**: page numbers, plus running heads such as the book or chapter title at the top of each page.
- **Finds chapters** from the PDF's bookmarks. If there are none, it finds them from headings: bigger type, or lines such as “Chapter 3” or “Prologue”. You get a working table of contents in Books.
- **Links things up.** A printed contents page becomes a list of links to the chapters, with the page numbers removed. Footnotes leave the flow of the text and open as pop-up notes in Books from their superscript markers, with a link back. Endnotes in a Notes section link both ways too, even when they're numbered afresh for each chapter. Any links the PDF already has, including web links, are kept.
- **Finds section headings** inside chapters, whether they're set larger, in bold, in capitals, or in another typeface, and gives them their own spacing.
- **Keeps italics and bold**, even in PDFs (often from InDesign) where macOS reports every font as Helvetica: it reads which font really drew each word from the page itself, including words slanted or outlined to fake italics or bold. Also keeps scene breaks (`* * *` or a large gap), and drop caps (a large first letter gets reattached to its word).
- **Makes a cover** from the first page.
- **Reads scanned books** with macOS's built-in text recognition (Vision) when a page holds only a picture of text.
- **Keeps illustration pages** (a picture with a short caption) as images.
- **Leaves typography to you**: fonts, alignment and colours aren't forced, so Books' themes and font choices work normally.

The output is EPUB 3, with an EPUB 2 table of contents included for older readers, and it passes [EPUBCheck](https://www.w3.org/publishing/epubcheck/) with no errors or warnings.

## Using it

1. Open **PDF to EPUB**.
2. Drop a PDF on the window, or click **Choose PDF…**. You can also drop a PDF on the app's Dock icon or use Finder's *Open With*.
3. Check the title and author, which come from the PDF where possible.
4. Click **Convert to EPUB…** and pick where to save. With “Open in Books when done” on, the book goes straight into your Books library.

### Options

| Option | What it's for |
| --- | --- |
| Use the first page as the cover | Makes the cover image from page 1. If page 1 is mostly a picture, it's left out of the text. |
| Remove page numbers and running headers | Turn off only if real text is going missing from the tops or bottoms of pages. |
| Use the PDF's bookmarks for chapters | Turn off if the bookmarks are poor (for example one per page) to find chapters from headings instead. |
| Read scanned pages with text recognition | Slower, but needed for scanned books. |
| Keep illustration pages as pictures | Pages that are mostly an image become a full-width image in the book. |

### Command line

The app includes a command-line version:

```sh
"/Applications/PDF to EPUB.app/Contents/Resources/pdf2epub" book.pdf --open
pdf2epub book.pdf -o ~/Desktop/book.epub --title "Better Title" --author "Someone"
pdf2epub --help
```

This is handy for converting a stack of books, or for checking what the converter makes of a tricky PDF: it lists the chapters it found.

## Installing

### Download

Get **PDF-to-EPUB.zip** from the [Releases page](https://github.com/writingpoli/pdf-to-epub-converter/releases/latest), unzip it and drag **PDF to EPUB.app** into Applications. It needs macOS 13 or later.

The app is signed ad hoc, not notarized by Apple, so the first time you open it macOS will say it can't check it. On macOS 15 or later, open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. On earlier versions, right-click the app, choose **Open**, then **Open** again. You can also clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine "/Applications/PDF to EPUB.app"
```

### Build it yourself

You'll need macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/writingpoli/pdf-to-epub-converter
cd pdf-to-epub-converter
scripts/build-app.sh
open dist
```

Drag **PDF to EPUB.app** into Applications.

### Test builds

GitHub Actions also builds the app when started by hand (**Actions → CI → Run workflow**). Open the run and download the **PDF-to-EPUB-app** artifact (you need to be signed in to GitHub). Pushing a version tag such as `v1.2.0` builds the app and publishes it on the Releases page.

## When a book comes out wrong

Choose the PDF in the app and click **Diagnostics…**. Give it the number of a page (as Preview shows it) where something goes wrong: missing italics, a heading run into the text, a stray page number. It copies a short report to the clipboard: the PDF's fonts as macOS reports them, the lines of that page with their sizes and positions, and what the converter made of them. The text is masked (“Xxxxx xxx”), so the report shows layout without the book's words. Paste it into an issue or a message to whoever is helping.

## Limitations

The converter works well for what most PDF books are: a single column of prose. Some layouts are beyond what can be recovered from a PDF reliably:

- **Multi-column pages and sidebars** come out in the order the PDF stores them, which isn't always reading order.
- **Notes** are found by their small type and leading number (footnotes) or under a “Notes” heading (endnotes), and matched to superscript references. Notes marked in unusual ways, or references that aren't set as smaller raised numbers, stay as plain text.
- **Pictures inside text pages** are dropped. Only pages that are mostly a picture are kept.
- **Tables, equations and poetry** lose some of their layout. Each line of verse usually becomes its own short paragraph.
- **Password-protected PDFs** need unlocking first (open in Preview, then *File → Export as PDF*).
- Heading detection is a guess based on type size. If a book's chapters don't split well, try the bookmarks option both ways.

## How it works

```
PDF ──PDFKit──▶ lines with position, size, style ──LayoutAnalyzer──▶ chapters ──EPUBWriter──▶ .epub
       └ Vision OCR for scanned pages
```

- `Sources/PDFToEPUBCore/PDFExtractor.swift` reads each line's text, position, font size and bold/italic runs through PDFKit. It runs Vision text recognition on image-only pages, spots illustration pages, and reads the bookmarks.
- `Sources/PDFToEPUBCore/LayoutAnalyzer.swift` does the reconstruction. It works out the body text size, margins and line spacing for each page. Then it removes repeated heads and page numbers, decides where paragraphs start (indent style or gap style), rejoins hyphenated words, and ranks headings by size to split chapters.
- `Sources/PDFToEPUBCore/EPUBWriter.swift` and `ZipWriter.swift` write the EPUB with no third-party dependencies.
- `Sources/PDFToEPUB` is the SwiftUI app, and `Sources/pdf2epub` is the command-line tool.

The layout and EPUB code is plain Swift, so its tests also run on Linux. The tests that go through PDFKit run on macOS.

## Development

```sh
swift build
swift test
swift run PDFToEPUB     # run the app without bundling it
swift run pdf2epub Tests/Fixtures/alice-sample.pdf -o /tmp/alice.epub
```

`Tests/Fixtures` holds a sample book PDF made by `scripts/make_sample_pdf.py` (public-domain text from *Alice's Adventures in Wonderland*). It deliberately includes the awkward parts: a picture cover, a printed contents page, changing running heads, page numbers, hyphenated justified text, a scene break, an illustration plate, a footnote, endnotes, and bookmarks with clickable contents entries (there's also a copy with no bookmarks or links, to test the fallbacks).

## License

Copyright © 2026 writingpoli. All rights reserved. You may download or build the app and use it for your own personal, non-commercial use; you may not redistribute, modify for distribution, or sell it, or use it commercially, without permission. See [LICENSE](LICENSE).
