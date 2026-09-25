import XCTest
@testable import PDFToEPUBCore

final class LinkTests: XCTestCase {
    func line(_ runs: [TextRun], page: Int, y: Double, x: Double = 50, width: Double = 320, size: Double = 11) -> TextLine {
        TextLine(runs: runs, page: page, x: x, y: y, width: width, height: size * 1.15, fontSize: size,
                 pageWidth: 420, pageHeight: 595)
    }

    func line(_ text: String, page: Int, y: Double, x: Double = 50, width: Double = 320, size: Double = 11) -> TextLine {
        line([TextRun(text: text)], page: page, y: y, x: x, width: width, size: size)
    }

    func allRuns(_ chapters: [Chapter]) -> [TextRun] {
        chapters.flatMap(\.blocks).flatMap { $0.runs ?? [] }
    }

    func anchors(_ chapters: [Chapter]) -> Set<String> {
        var ids = Set<String>()
        for block in chapters.flatMap(\.blocks) {
            switch block {
            case .anchor(let id), .footnote(let id, _): ids.insert(id)
            default: break
            }
            for run in block.runs ?? [] { if let id = run.id { ids.insert(id) } }
        }
        return ids
    }

    /// Every internal link points at an id that exists.
    func assertLinksResolve(_ chapters: [Chapter], file: StaticString = #filePath, line: UInt = #line) {
        let ids = anchors(chapters)
        for run in allRuns(chapters) {
            switch run.link {
            case .anchor(let id): XCTAssertTrue(ids.contains(id), "dangling link to \(id)", file: file, line: line)
            case .page: XCTFail("unresolved page link on “\(run.text)”", file: file, line: line)
            default: break
            }
        }
    }

    // MARK: -

    func testModifySplitsRuns() {
        var runs = [TextRun(text: "Hello "), TextRun(text: "wide", italic: true), TextRun(text: " world")]
        runs.modify(characters: 3..<8) { $0.bold = true }
        XCTAssertEqual(runs.map(\.text), ["Hel", "lo ", "wi", "de", " world"])
        XCTAssertEqual(runs.map(\.bold), [false, true, true, false, false])
        XCTAssertEqual(runs.map(\.italic), [false, false, true, true, false])
    }

    func testAddLinkIgnoresSpacing() {
        var l = line("See Chapter  Two for more", page: 0, y: 0)
        XCTAssertTrue(l.addLink(.anchor("x"), text: "Chapter Two"))
        XCTAssertEqual(l.runs.filter { $0.link != nil }.map(\.text).joined(), "Chapter  Two")
        XCTAssertFalse(l.addLink(.anchor("y"), text: "Chapter Three"))
    }

    func testFootnotesLeaveTheFlowAndLinkBothWays() {
        var lines: [TextLine] = []
        var y = 60.0
        for i in 0..<8 {
            var runs = [TextRun(text: "Body line \(i) of the page, with plenty of words to fill")]
            if i == 3 { runs.append(TextRun(text: "1", superscript: true)) }
            lines.append(line(runs, page: 0, y: y, x: i == 0 ? 66 : 50))
            y += 14
        }
        lines.append(line([TextRun(text: "1", superscript: true), TextRun(text: " The footnote text, which runs")],
                          page: 0, y: 520, size: 9))
        lines.append(line("onto a second line.", page: 0, y: 531, size: 9))
        // The paragraph carries on over the page turn.
        lines.append(line("and continues here on the next page.", page: 1, y: 60, width: 200))

        let chapters = LayoutAnalyzer().analyze(lines: lines)
        let blocks = chapters.flatMap(\.blocks)
        guard case .footnote(let id, let noteRuns)? = blocks.last else { return XCTFail("no footnote: \(blocks)") }
        XCTAssertEqual(noteRuns.joinedText, "1 The footnote text, which runs onto a second line.")

        let paragraphs = blocks.compactMap { b -> String? in
            if case .paragraph(let runs, _) = b { return runs.joinedText } else { return nil }
        }
        XCTAssertEqual(paragraphs.count, 1, "the footnote must not split the paragraph: \(paragraphs)")
        XCTAssertTrue(paragraphs[0].hasSuffix("and continues here on the next page."))

        let ref = allRuns(chapters).first { $0.superscript }
        XCTAssertEqual(ref?.link, .anchor(id))
        XCTAssertEqual(noteRuns.first?.link, ref?.id.map { .anchor($0) })
        assertLinksResolve(chapters)
    }

    /// PDF readers can hand back a raised note number as its own small line.
    func testRaisedMarkerSliverBecomesANoteReference() {
        var lines: [TextLine] = []
        for i in 0..<6 {
            lines.append(line("Body line \(i) of the page, with plenty of words to fill", page: 0,
                              y: 60 + Double(i) * 14, x: i == 0 ? 66 : 50, width: i == 3 ? 300 : 320))
        }
        // "1" sits just after line 3, a little higher and smaller.
        lines.append(TextLine(runs: [TextRun(text: "1")], page: 0, x: 351, y: 60 + 3 * 14 - 2.5, width: 4,
                              height: 8, fontSize: 7, pageWidth: 420, pageHeight: 595))
        lines.append(line("1 The note itself.", page: 0, y: 520, width: 120, size: 9))

        let chapters = LayoutAnalyzer().analyze(lines: lines)
        let refs = allRuns(chapters).filter(\.superscript)
        XCTAssertEqual(refs.map(\.text), ["1"])
        XCTAssertEqual(refs.first?.link, .anchor("fn1-1"))
        let paragraphs = chapters.flatMap(\.blocks).compactMap { b -> String? in
            if case .paragraph(let runs, _) = b { return runs.joinedText } else { return nil }
        }
        XCTAssertEqual(paragraphs.count, 1, "\(paragraphs)")
        XCTAssertTrue(paragraphs[0].contains("line 3 of the page, with plenty of words to fill1 Body line 4"),
                      paragraphs[0])
        assertLinksResolve(chapters)
    }

    func testContentsPageLinksToChapters() {
        var lines: [TextLine] = [
            line("Contents", page: 0, y: 60, x: 170, width: 80, size: 16),
            line("Chapter One: Beginnings ........ 2", page: 0, y: 110),
            line("Chapter Two: Middles ........... 3", page: 0, y: 124),
            line("Chapter Three: Endings ........ 4", page: 0, y: 138),
        ]
        let titles = ["Chapter One: Beginnings", "Chapter Two: Middles", "Chapter Three: Endings"]
        for (i, title) in titles.enumerated() {
            let page = i + 1
            lines.append(line(title, page: page, y: 80, x: 120, width: 200, size: 18))
            for k in 0..<6 {
                lines.append(line("Text of \(title) line \(k) that fills the measure nicely.", page: page,
                                  y: 130 + Double(k) * 14, x: k == 0 ? 66 : 50))
            }
        }
        let chapters = LayoutAnalyzer().analyze(lines: lines)
        XCTAssertEqual(chapters.map(\.title), ["Contents"] + titles)

        let entries = chapters[0].blocks.compactMap { b -> [TextRun]? in
            if case .paragraph(let runs, _) = b { return runs } else { return nil }
        }
        XCTAssertEqual(entries.map(\.joinedText), titles, "page numbers and leaders should be gone")
        for (i, runs) in entries.enumerated() {
            guard case .anchor(let id)? = runs.first?.link else { return XCTFail("entry \(i) not linked") }
            XCTAssertTrue(chapters[i + 1].blocks.contains(.anchor(id)), "entry \(i) should point into its chapter")
        }
        assertLinksResolve(chapters)
    }

    func testContentsFallsBackToPrintedPageNumbers() {
        var lines: [TextLine] = [
            line("Contents", page: 0, y: 60, x: 170, width: 80, size: 16),
            line("A Walk in the Park  3", page: 0, y: 110),
            line("Rain  4", page: 0, y: 124),
            line("Home Again  5", page: 0, y: 138),
        ]
        // No headings at all; printed page number = PDF page + 2.
        for page in 1...3 {
            for k in 0..<6 {
                lines.append(line("Page \(page) text line \(k) that goes all the way across.", page: page,
                                  y: 80 + Double(k) * 14, x: k == 0 ? 66 : 50))
            }
            lines.append(line("\(page + 2)", page: page, y: 560, x: 205, width: 10, size: 9))
        }
        let chapters = LayoutAnalyzer().analyze(lines: lines)
        let runs = allRuns(chapters)
        let rain = runs.first { $0.text == "Rain" }
        guard case .anchor(let id)? = rain?.link else { return XCTFail("Rain not linked") }
        let blocks = chapters.flatMap(\.blocks)
        let at = blocks.firstIndex(of: .anchor(id))!
        XCTAssertTrue(blocks[at + 1].runs?.joinedText.hasPrefix("Page 2 text") ?? false)
        assertLinksResolve(chapters)
    }

    func testPDFLinksResolveToTheBlockAtTheirTarget() {
        var lines: [TextLine] = []
        var first = line("As explained in the second part, links should work.", page: 0, y: 60, width: 250)
        first.addLink(.page(1, y: 100), text: "the second part")
        lines.append(first)
        lines.append(line("First paragraph on page two.", page: 1, y: 60, x: 66, width: 200))
        lines.append(line("Second paragraph on page two, the target.", page: 1, y: 104, x: 66, width: 250))
        let chapters = LayoutAnalyzer().analyze(lines: lines)
        let link = allRuns(chapters).first { $0.link != nil }?.link
        guard case .anchor(let id)? = link else { return XCTFail("not resolved") }
        let blocks = chapters.flatMap(\.blocks)
        let at = blocks.firstIndex(of: .anchor(id))!
        XCTAssertEqual(blocks[at + 1].runs?.joinedText, "Second paragraph on page two, the target.")
    }

    func testEndnotesLinkByChapter() {
        var lines: [TextLine] = []
        func chapter(_ title: String, page: Int, refs: [Int]) {
            lines.append(line(title, page: page, y: 80, x: 150, width: 120, size: 18))
            for (k, ref) in refs.enumerated() {
                lines.append(line([TextRun(text: "A cited sentence number \(k) in \(title), long enough"),
                                   TextRun(text: "\(ref)", superscript: true)],
                                  page: page, y: 130 + Double(k) * 14, x: 66))
            }
        }
        chapter("One", page: 0, refs: [1, 2])
        chapter("Two", page: 1, refs: [1])
        lines.append(line("Notes", page: 2, y: 80, x: 170, width: 60, size: 18))
        lines.append(line("One", page: 2, y: 120, x: 50, width: 40, size: 13))
        lines.append(line("1. First note for chapter one, which is long enough", page: 2, y: 150))
        lines.append(line("to wrap onto a hanging indent.", page: 2, y: 164, x: 62, width: 150))
        lines.append(line("2. Second note for chapter one.", page: 2, y: 178, width: 180))
        lines.append(line("Two", page: 2, y: 210, x: 50, width: 40, size: 13))
        lines.append(line("1. Only note for chapter two.", page: 2, y: 240, width: 170))

        let chapters = LayoutAnalyzer().analyze(lines: lines)
        XCTAssertEqual(chapters.map(\.title), ["One", "Two", "Notes"])
        let refs = allRuns(Array(chapters[0...1])).filter(\.superscript)
        XCTAssertEqual(refs.map(\.link), [.anchor("en1-1"), .anchor("en1-2"), .anchor("en2-1")])

        let notes = chapters[2].blocks.compactMap { b -> String? in
            if case .paragraph(let runs, _) = b { return runs.joinedText } else { return nil }
        }
        XCTAssertEqual(notes.first, "1. First note for chapter one, which is long enough to wrap onto a hanging indent.")
        XCTAssertEqual(notes.count, 3)
        assertLinksResolve(chapters)
    }

    func testWriterMarksNoteReferencesAndLinksAcrossFiles() {
        let writer = EPUBWriter()
        let runs = [TextRun(text: "Word"), TextRun(text: "3", superscript: true, link: .anchor("n3"), id: "r3")]
        XCTAssertEqual(writer.inline(runs, targets: ["n3": "ch002.xhtml", "r3": "ch001.xhtml"], file: "ch001.xhtml"),
                       "Word<a id=\"r3\" epub:type=\"noteref\" href=\"ch002.xhtml#n3\"><sup>3</sup></a>")
        XCTAssertEqual(writer.inline([TextRun(text: "x", link: .anchor("missing"))]), "x")
        XCTAssertEqual(writer.inline([TextRun(text: "site", link: .url("javascript:alert(1)"))]), "site")
    }
}
