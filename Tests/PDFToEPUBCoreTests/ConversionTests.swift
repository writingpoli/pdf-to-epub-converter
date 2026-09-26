#if canImport(PDFKit)
import XCTest
import PDFKit
@testable import PDFToEPUBCore

/// End-to-end: real PDFs through PDFKit, out to an EPUB, unpacked with `unzip`.
final class ConversionTests: XCTestCase {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    func convert(_ name: String, configure: (inout ConversionOptions) -> Void = { _ in })
        throws -> (result: ConversionResult, text: String, files: [String]) {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        var options = ConversionOptions()
        configure(&options)
        let result = try PDFToEPUBConverter.convert(input: fixtures.appendingPathComponent(name),
                                                    output: output, options: options)
        let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", output.path, "-d", unpacked.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)

        let files = (FileManager.default.enumerator(atPath: unpacked.path)?.allObjects as? [String] ?? []).sorted()
        let text = try files.filter { $0.hasPrefix("OEBPS/text/ch") }.sorted().map {
            try String(contentsOf: unpacked.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        return (result, text, files)
    }

    let chapterTitles = ["CHAPTER I. Down the Rabbit-Hole", "CHAPTER II. The Pool of Tears",
                         "CHAPTER III. A Caucus-Race and a Long Tale", "Notes"]

    func testConvertsSampleWithBookmarks() throws {
        let (result, text, files) = try convert("alice-sample.pdf")
        XCTAssertEqual(result.pageCount, 12)
        XCTAssertTrue(result.usedOutline)
        XCTAssertEqual(Array(result.chapterTitles.suffix(4)), chapterTitles)
        XCTAssertTrue(files.contains("OEBPS/images/cover.jpg"))
        XCTAssertEqual(result.imagePageCount, 1, "the illustration plate should be kept as a picture")

        // Hyphenation undone, compounds kept, italics kept, furniture gone.
        XCTAssertTrue(text.contains("pictures or conversations?"), text)
        XCTAssertTrue(text.contains("waistcoat-pocket"))
        XCTAssertTrue(text.contains("so <em>very</em> remarkable"), text)
        XCTAssertTrue(text.contains("labelled “<strong>ORANGE MARMALADE</strong>”"), "bold in running text")
        XCTAssertFalse(text.contains("conversa-"))
        XCTAssertFalse(text.contains("<p>Alice’s Adventures in Wonderland</p>"))
        XCTAssertFalse(text.contains("<p><em>Down the Rabbit-Hole</em></p>"), text)
        XCTAssertTrue(text.contains("<hr class=\"scene\"/>"))
        // A paragraph that runs over a page turn stays whole.
        XCTAssertTrue(text.contains("even if I fell off the top of the house!” (Which was very likely true.)"), text)
        try assertLinks(text)
    }

    func testFindsChaptersWithoutBookmarks() throws {
        let (result, text, _) = try convert("alice-no-bookmarks.pdf")
        XCTAssertFalse(result.usedOutline)
        XCTAssertEqual(Array(result.chapterTitles.suffix(4)), chapterTitles)
        try assertLinks(text)
    }

    /// Contents entries, the footnote and the endnotes all link where they should.
    func assertLinks(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        func has(_ fragment: String) {
            XCTAssertTrue(text.contains(fragment), "missing \(fragment)", file: file, line: line)
        }
        // Contents: each entry is a link, without its page number.
        for title in chapterTitles {
            XCTAssertNotNil(text.range(of: "<a href=\"ch0\\d\\d\\.xhtml#[^\"]+\">\(title)</a></p>",
                                       options: .regularExpression), "contents entry \(title)", file: file, line: line)
        }
        // Footnote: the reference pops up the note, which links back.
        has("epub:type=\"noteref\" href=\"#fn")
        has("<aside epub:type=\"footnote\"")
        has("boat trip up the Thames in July 1862.</p></aside>")
        // Endnotes, numbered afresh for each chapter.
        has("id=\"en1-1\"")
        has("id=\"en1-2\"")
        has("id=\"en2-1\"")
        XCTAssertEqual(text.components(separatedBy: "epub:type=\"noteref\"").count - 1, 4,
                       "one footnote and three endnote references", file: file, line: line)
        // Every note reference leads to a note (the bookmarked PDF points three at the contents page).
        let noteHrefs = text.components(separatedBy: "epub:type=\"noteref\" href=\"").dropFirst()
            .map { $0.prefix { $0 != "\"" } }
        for href in noteHrefs {
            XCTAssertTrue(href.contains("#fn") || href.contains("#en"), "note links to \(href)", file: file, line: line)
        }
        // A bold section heading at body size is a heading of its own.
        XCTAssertNotNil(text.range(of: "<h[1-3][^>]*>A Long and a Sad Tale</h[1-3]>", options: .regularExpression),
                        "section heading", file: file, line: line)
    }

    /// Layout tools often share one resource list between every page and every
    /// embedded graphic. Checking it for pictures used to take minutes per page.
    func testSharedResourcesDoNotStall() throws {
        let started = Date()
        let (result, text, _) = try convert("shared-resources.pdf")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertTrue(text.contains("shares its resources"), text)
    }

    /// Fonts whose names don't give their style away (as in InDesign books,
    /// where PDFKit may also report everything as Helvetica): emphasis comes
    /// from the fonts' descriptors and from how the text is drawn.
    func testEmphasisFromEmbeddedFonts() throws {
        let (_, text, _) = try convert("embedded-fonts.pdf") { $0.includeCover = false }
        XCTAssertTrue(text.contains("<em>italics</em>"), "italic font\n\(text)")
        XCTAssertTrue(text.contains("<em>slanted</em>"), "regular font drawn slanted")
        XCTAssertTrue(text.contains("<strong>bold</strong>"), "bold font")
        XCTAssertTrue(text.contains("<strong>outlined</strong>"), "regular font drawn outlined")
        XCTAssertNotNil(text.range(of: "<h[1-3][^>]*>A Section at Body Size</h[1-3]>", options: .regularExpression),
                        "bold section heading at body size")
        XCTAssertFalse(text.contains("<strong>The first paragraph"), "body text stays regular")
    }

    /// The fallback for lines that can't be matched character by character:
    /// styles worked out from the order of the text drawn along the line.
    func testEstimatedFontsFromDrawingOrder() throws {
        let document = try XCTUnwrap(PDFDocument(url: fixtures.appendingPathComponent("embedded-fonts.pdf")))
        let page = try XCTUnwrap(document.page(at: 0))
        let lines = page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []
        let selection = try XCTUnwrap(lines.first { $0.string?.contains("set in the italic font") == true })
        let extractor = PDFExtractor(document: document)
        let estimate = try XCTUnwrap(extractor.estimatedFonts(for: selection.string ?? "", bounds: selection.bounds(for: page),
                                                              map: PDFFontMap(page: page)))
        let italic = estimate.runs.filter(\.italic).map(\.text).joined()
        XCTAssertEqual(italic.trimmingCharacters(in: .whitespaces), "italics", "\(estimate.runs)")
        XCTAssertEqual(estimate.family, "Serif")
    }

    func testTitleAndAuthorOverrides() throws {
        let (_, text, _) = try convert("alice-sample.pdf") { options in
            options.title = "My Title"
            options.author = "Someone"
        }
        XCTAssertFalse(text.isEmpty)
        let details = PDFToEPUBConverter.details(for: fixtures.appendingPathComponent("alice-sample.pdf"))
        XCTAssertEqual(details?.title, "Alice’s Adventures in Wonderland")
        XCTAssertEqual(details?.author, "Lewis Carroll")
    }
}
#endif
