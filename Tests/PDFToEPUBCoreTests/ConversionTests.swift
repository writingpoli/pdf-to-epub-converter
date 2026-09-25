#if canImport(PDFKit)
import XCTest
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

    func testConvertsSampleWithBookmarks() throws {
        let (result, text, files) = try convert("alice-sample.pdf")
        XCTAssertEqual(result.pageCount, 10)
        XCTAssertTrue(result.usedOutline)
        XCTAssertEqual(result.chapterTitles.suffix(3), ["CHAPTER I. Down the Rabbit-Hole",
                                                        "CHAPTER II. The Pool of Tears",
                                                        "CHAPTER III. A Caucus-Race and a Long Tale"])
        XCTAssertTrue(files.contains("OEBPS/images/cover.jpg"))
        XCTAssertEqual(result.imagePageCount, 1, "the illustration plate should be kept as a picture")

        // Hyphenation undone, compounds kept, italics kept, furniture gone.
        XCTAssertTrue(text.contains("pictures or conversations?"), text)
        XCTAssertTrue(text.contains("waistcoat-pocket"))
        XCTAssertTrue(text.contains("so <em>very</em> remarkable"), text)
        XCTAssertFalse(text.contains("conversa-"))
        XCTAssertFalse(text.contains("<p>Alice’s Adventures in Wonderland</p>"))
        XCTAssertFalse(text.contains("<p><em>Down the Rabbit-Hole</em></p>"), text)
        XCTAssertTrue(text.contains("<hr class=\"scene\"/>"))
        // A paragraph that runs over a page turn stays whole.
        XCTAssertTrue(text.contains("even if I fell off the top of the house!” (Which was very likely true.)"), text)
    }

    func testFindsChaptersWithoutBookmarks() throws {
        let (result, _, _) = try convert("alice-no-bookmarks.pdf")
        XCTAssertFalse(result.usedOutline)
        XCTAssertEqual(result.chapterTitles.suffix(3), ["CHAPTER I. Down the Rabbit-Hole",
                                                        "CHAPTER II. The Pool of Tears",
                                                        "CHAPTER III. A Caucus-Race and a Long Tale"])
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
