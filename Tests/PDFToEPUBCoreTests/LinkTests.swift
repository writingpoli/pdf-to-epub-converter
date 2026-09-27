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

    /// What PDFKit reports for a raised note number set at full size.
    func testAttachedNumberRunsAreNoteMarkers() {
        var runs = [TextRun(text: "get out again."), TextRun(text: "1"), TextRun(text: " Then")]
        runs.markAttachedNoteMarkers()
        XCTAssertEqual(runs.map(\.superscript), [false, true, false])

        // Not markers: a number after a space, or one that runs into more text.
        var other = [TextRun(text: "chapter "), TextRun(text: "12"), TextRun(text: "B", italic: true),
                     TextRun(text: "x"), TextRun(text: "2"), TextRun(text: "nd")]
        other.markAttachedNoteMarkers()
        XCTAssertEqual(other.map(\.superscript), [false, false, false, false, false, false])
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

final class SectionHeadingTests: XCTestCase {
    /// A page of indented body text with one candidate line in the middle,
    /// set with extra space above it and ordinary spacing below.
    func analyze(_ candidate: TextLine) -> [Block] {
        var lines: [TextLine] = []
        var y = 60.0
        func body(_ i: Int, font: String = "Minion") {
            lines.append(TextLine(runs: [TextRun(text: "Body text line \(i) runs all the way across the measure here")],
                                  page: 0, x: i % 4 == 0 ? 66 : 50, y: y, width: i % 4 == 0 ? 304 : 320, height: 12.6,
                                  fontSize: 11, pageWidth: 420, pageHeight: 595, fontName: font))
            y += 14
        }
        for i in 0..<8 { body(i) }
        y += 12
        var line = candidate
        line.y = y
        lines.append(line)
        y += 16
        for i in 8..<16 { body(i) }
        return LayoutAnalyzer().analyze(lines: lines).flatMap(\.blocks)
    }

    func candidate(_ text: String, bold: Bool = false, italic: Bool = false, font: String = "Minion",
                   size: Double = 11, width: Double = 150) -> TextLine {
        TextLine(runs: [TextRun(text: text, bold: bold, italic: italic)], page: 0, x: 50, y: 0, width: width,
                 height: size * 1.15, fontSize: size, pageWidth: 420, pageHeight: 595, fontName: font)
    }

    func headingTexts(_ blocks: [Block]) -> [String] {
        blocks.compactMap { if case .heading(_, let runs) = $0 { return runs.joinedText } else { return nil } }
    }

    func testBoldSectionHeadingAtBodySize() {
        XCTAssertEqual(headingTexts(analyze(candidate("The Road North", bold: true))), ["The Road North"])
    }

    func testCapitalsSectionHeading() {
        XCTAssertEqual(headingTexts(analyze(candidate("THE ROAD NORTH"))), ["THE ROAD NORTH"])
    }

    func testDifferentTypefaceSectionHeading() {
        XCTAssertEqual(headingTexts(analyze(candidate("The Road North", font: "Gill Sans"))), ["The Road North"])
    }

    func testSlightlyLargerSectionHeading() {
        XCTAssertEqual(headingTexts(analyze(candidate("The Road North", size: 12.5))), ["The Road North"])
    }

    func testSentencesAreNotHeadings() {
        XCTAssertEqual(headingTexts(analyze(candidate("He left at dawn.", bold: true))), [])
        XCTAssertEqual(headingTexts(analyze(candidate("An ordinary short line"))), [])
        XCTAssertEqual(headingTexts(analyze(candidate(String(repeating: "Bold words ", count: 10), bold: true,
                                                      width: 320))), [])
    }

    func testHeadingIsItsOwnBlockBetweenParagraphs() {
        let blocks = analyze(candidate("The Road North", bold: true))
        guard let at = blocks.firstIndex(where: { if case .heading = $0 { return true } else { return false } }) else {
            return XCTFail("no heading")
        }
        guard case .paragraph(let before, _) = blocks[at - 1], case .paragraph(let after, _) = blocks[at + 1] else {
            return XCTFail("heading should sit between paragraphs")
        }
        XCTAssertTrue(before.joinedText.hasSuffix("line 7 runs all the way across the measure here"))
        XCTAssertTrue(after.joinedText.hasPrefix("Body text line 8"))
    }
}

extension LinkTests {
    /// Some PDFs link note markers to the front of the book. Those links are
    /// dropped, and the marker is matched to its endnote instead.
    func testMisreadNoteNumbersFollowTheSequence() {
        XCTAssertEqual(LayoutAnalyzer.sequenced([1, 2, 3, 4, 5, 4, 7, 8]), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(LayoutAnalyzer.sequenced([4, 2, 3]), [1, 2, 3])
        XCTAssertEqual(LayoutAnalyzer.sequenced([1, 2, 3, 2, 4, 5]), [1, 2, 3, 2, 4, 5], "a note cited again")
        XCTAssertEqual(LayoutAnalyzer.sequenced([12, 13, 14]), [12, 13, 14], "numbered through the book")
        XCTAssertEqual(LayoutAnalyzer.sequenced([1, 4, 4, 9, 4, 4, 7]), [1, 2, 3, 4, 5, 6, 7], "mostly unreadable: order")
        XCTAssertEqual(LayoutAnalyzer.sequenced([1, 2, 0, 4]), [1, 2, 3, 4], "recovered marker, number unknown")
        XCTAssertEqual(LayoutAnalyzer.sequenced([0, 0, 0]), [1, 2, 3])
    }

    func testInsertRunAtCharacter() {
        var runs = [TextRun(text: "word. "), TextRun(text: "Next", italic: true)]
        runs.insert(TextRun(text: "*", superscript: true), atCharacter: 5)
        XCTAssertEqual(runs.map(\.text), ["word.", "*", " ", "Next"])
        runs.insert(TextRun(text: "*", superscript: true), atCharacter: 11)
        XCTAssertEqual(runs.map(\.text).joined(), "word.* Next*")
    }

    /// A note's later paragraphs, and lines that start with a number, belong
    /// to it; a marker whose digit was misread still finds its note.
    func testWholeNotesAndMisreadMarkers() {
        var lines: [TextLine] = []
        lines.append(line("One", page: 0, y: 80, x: 150, width: 120, size: 18))
        for (k, ref) in [1, 2, 1, 4].enumerated() {   // the third marker is a misread 3
            lines.append(line([TextRun(text: "A cited sentence number \(k) in chapter one, long enough"),
                               TextRun(text: "\(ref)", superscript: true)],
                              page: 0, y: 130 + Double(k) * 14, x: 66))
        }
        lines.append(line("Notes", page: 1, y: 80, x: 170, width: 60, size: 18))
        lines.append(line("1. First note, which runs to one sentence.", page: 1, y: 130, width: 220))
        lines.append(line("It has a second paragraph, too.", page: 1, y: 150, x: 62, width: 180))
        lines.append(line("2. Second note, citing a journal:", page: 1, y: 170, width: 200))
        lines.append(line("12 (3): 45–67.", page: 1, y: 184, width: 100))
        lines.append(line("3. Third note.", page: 1, y: 204, width: 100))
        lines.append(line("4. Fourth note.", page: 1, y: 218, width: 100))

        let chapters = LayoutAnalyzer().analyze(lines: lines)
        let refs = allRuns([chapters[0]]).filter(\.superscript)
        XCTAssertEqual(refs.map(\.link), [.anchor("en1-1"), .anchor("en1-2"), .anchor("en1-3"), .anchor("en1-4")])
        let notes = chapters[1].blocks.compactMap { b -> String? in
            if case .paragraph(let runs, _) = b { return runs.joinedText } else { return nil }
        }
        XCTAssertEqual(notes.map { $0.replacingOccurrences(of: "\n", with: " ") },
                       ["1. First note, which runs to one sentence. It has a second paragraph, too.",
                        "2. Second note, citing a journal: 12 (3): 45–67.", "3. Third note.", "4. Fourth note."])
        assertLinksResolve(chapters)
    }

    func testNotesReportSummarisesLinks() {
        var lines: [TextLine] = []
        lines.append(line("One", page: 0, y: 80, x: 150, width: 120, size: 18))
        for (k, ref) in [1, 2].enumerated() {
            lines.append(line([TextRun(text: "A cited sentence number \(k) in chapter one, long enough"),
                               TextRun(text: "\(ref)", superscript: true)],
                              page: 0, y: 130 + Double(k) * 14, x: 66))
        }
        lines.append(line("Notes", page: 1, y: 80, x: 170, width: 60, size: 18))
        lines.append(line("1. First note.", page: 1, y: 130, width: 120))
        lines.append(line("2. Second note.", page: 1, y: 144, width: 120))
        let chapters = LayoutAnalyzer().analyze(lines: lines)
        let report = NotesReport.summary(chapters) { $0 }
        XCTAssertTrue(report.contains("2 linked to endnotes"), report)
        XCTAssertTrue(report.contains("group 1: notes 1–2 (2)"), report)
        XCTAssertTrue(report.contains("cited from \"One\" (2 markers)"), report)
        let trace = NotesReport.trace(marker: "2", after: "number 1 in chapter one, long enough", in: chapters) { $0 }
        XCTAssertTrue(trace.contains("links to en1-2: \"2. Second note.…\""), trace)
    }

    /// The PDF's links from markers often lead only to the page a note is
    /// on. They say whose notes to look in; the number says which note.
    func testPageLinksFromMarkersFindTheNoteByNumber() {
        var lines: [TextLine] = []
        func chapter(_ title: String, page: Int, refs: [Int]) {
            lines.append(line(title, page: page, y: 80, x: 150, width: 120, size: 18))
            for (k, ref) in refs.enumerated() {
                lines.append(line([TextRun(text: "A cited sentence number \(k) in \(title), long enough"),
                                   TextRun(text: "\(ref)", superscript: true, link: .page(4, y: nil))],
                                  page: page, y: 130 + Double(k) * 14, x: 66))
            }
        }
        chapter("Alpha", page: 0, refs: [1, 2])
        chapter("Beta", page: 1, refs: [1, 2, 3])
        lines.append(line("Notes", page: 3, y: 80, x: 170, width: 60, size: 18))
        lines.append(line("Unmatched Name", page: 3, y: 120, x: 50, width: 90, size: 13))
        lines.append(line("1. First note, first group.", page: 3, y: 150, width: 170))
        lines.append(line("2. Second note, first group.", page: 3, y: 164, width: 170))
        lines.append(line("Another Name", page: 4, y: 60, x: 50, width: 80, size: 13))
        lines.append(line("1. First note, second group.", page: 4, y: 90, width: 170))
        lines.append(line("2. Second note, second group.", page: 4, y: 104, width: 170))
        lines.append(line("3. Third note, second group.", page: 4, y: 118, width: 170))

        let chapters = LayoutAnalyzer().analyze(lines: lines)
        let beta = allRuns([chapters[1]]).filter(\.superscript)
        XCTAssertEqual(beta.map(\.link), [.anchor("en2-1"), .anchor("en2-2"), .anchor("en2-3")])
        assertLinksResolve(chapters)
    }

    func testNoteMarkerLinkingBackwardsIsReplacedByItsEndnote() {
        var lines: [TextLine] = [
            line("Contents", page: 0, y: 60, x: 170, width: 80, size: 16),
            line("One ........ 2", page: 0, y: 110),
            line("Notes ........ 3", page: 0, y: 124),
            line("Another ........ 3", page: 0, y: 138),
            line("One", page: 1, y: 80, x: 190, width: 40, size: 18),
        ]
        lines.append(line([TextRun(text: "A sentence that cites a source, long enough to fill"),
                           TextRun(text: "1", link: .page(0, y: 60))], page: 1, y: 130, x: 66))
        lines.append(line("Notes", page: 2, y: 80, x: 180, width: 60, size: 18))
        lines.append(line("1. The source, cited in chapter one.", page: 2, y: 130, width: 200))
        lines.append(line("2. Another note that nothing cites.", page: 2, y: 144, width: 200))

        let chapters = LayoutAnalyzer().analyze(lines: lines)
        let ref = allRuns(chapters).first { $0.superscript }
        XCTAssertEqual(ref?.link, .anchor("en1-1"))
        assertLinksResolve(chapters)
    }
}

final class BulletTests: XCTestCase {
    func testBulletedLinesAreItemsNotHeadings() {
        var lines: [TextLine] = []
        var y = 60.0
        for i in 0..<5 {
            lines.append(TextLine(runs: [TextRun(text: "An introductory sentence number \(i) that runs across")],
                                  page: 0, x: i == 0 ? 66 : 50, y: y, width: i == 0 ? 304 : 320, height: 11.5,
                                  fontSize: 10, pageWidth: 420, pageHeight: 595))
            y += 13
        }
        for item in ["first item that is long enough to wrap onto", "second item", "third item"] {
            // The bullet arrives as its own larger fragment, drawn twice.
            lines.append(TextLine(runs: [TextRun(text: "●●")], page: 0, x: 60, y: y - 1, width: 8, height: 14,
                                  fontSize: 14, pageWidth: 420, pageHeight: 595))
            lines.append(TextLine(runs: [TextRun(text: item)], page: 0, x: 72, y: y, width: 250, height: 11.5,
                                  fontSize: 10, pageWidth: 420, pageHeight: 595))
            y += 13
        }
        let blocks = LayoutAnalyzer().analyze(lines: lines).flatMap(\.blocks)
        XCTAssertFalse(blocks.contains { if case .heading = $0 { return true } else { return false } }, "\(blocks)")
        let items = blocks.compactMap { b -> String? in
            if case .paragraph(let runs, _) = b, runs.joinedText.hasPrefix("●") { return runs.joinedText } else { return nil }
        }
        XCTAssertEqual(items, ["● first item that is long enough to wrap onto", "● second item", "● third item"])
    }

    /// A bullet item's wrapped lines sit indented under its text; they belong to the item.
    func testWrappedBulletLinesStayWithTheirItem() {
        var lines: [TextLine] = []
        var y = 60.0
        func add(_ text: String, x: Double, width: Double = 300) {
            lines.append(TextLine(runs: [TextRun(text: text)], page: 0, x: x, y: y, width: width, height: 11.5,
                                  fontSize: 10, pageWidth: 420, pageHeight: 595))
            y += 13
        }
        for i in 0..<4 { add("Body text line \(i) that runs the whole way across the page", x: i == 0 ? 52 : 40, width: 340) }
        add("● an item that is long enough to wrap onto the next line", x: 54)
        add("where it carries on;", x: 64, width: 100)
        add("● a second item", x: 54, width: 90)
        add("Back to the body text at the margin, running across.", x: 40, width: 340)
        let texts = LayoutAnalyzer().analyze(lines: lines).flatMap(\.blocks).compactMap { b -> String? in
            if case .paragraph(let runs, _) = b { return runs.joinedText } else { return nil }
        }
        XCTAssertTrue(texts.contains("● an item that is long enough to wrap onto the next line where it carries on;"), "\(texts)")
        XCTAssertTrue(texts.contains("● a second item"), "\(texts)")
    }

    func testBulletedParagraphsBecomeAList() {
        let book = Book(metadata: BookMetadata(title: "List"), chapters: [Chapter(title: "One", blocks: [
            .paragraph([TextRun(text: "Before.")], indented: false),
            .paragraph([TextRun(text: "● first "), TextRun(text: "item", italic: true)], indented: false),
            .paragraph([TextRun(text: "● second item")], indented: false),
            .paragraph([TextRun(text: "After.")], indented: false),
        ])])
        let writer = EPUBWriter()
        #if canImport(Compression)
        _ = writer.makeEPUB(book)
        #else
        let data = writer.makeEPUB(book)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("<ul class=\"bullets\">\n<li>first <em>item</em></li>\n<li>second item</li>\n</ul>"), text)
        XCTAssertTrue(text.contains("</ul>\n<p class=\"noindent\">After.</p>"))
        #endif
    }
}

final class BlockQuoteTests: XCTestCase {
    private var lines: [TextLine] = []
    private var y = 60.0

    private func add(_ text: String, x: Double, width: Double = 340, size: Double = 10, font: String? = "MinionPro",
                     gap: Double = 13) {
        lines.append(TextLine(runs: [TextRun(text: text)], page: 0, x: x, y: y, width: width, height: 11.5,
                              fontSize: size, pageWidth: 420, pageHeight: 595, fontName: font))
        y += gap
    }

    private func body(_ count: Int) {
        for i in 0..<count {
            add("Body text line \(i) that runs the whole way across the page", x: i == 0 ? 52 : 40,
                width: i == count - 1 ? 200 : 340, gap: i == count - 1 ? 19 : 13)
        }
    }

    /// Text set in from the margin on every line, then its source, then the
    /// body again: a quotation, not paragraphs or a heading.
    func testIndentedPassageIsAQuote() {
        body(5)
        add("A long quotation that is set in from both margins and runs", x: 58, width: 310, size: 9, gap: 12)
        add("over several lines, all of them starting at the same place,", x: 58, width: 310, size: 9, gap: 12)
        add("until it ends here.", x: 58, width: 100, size: 9, gap: 12)
        add("(Somebody 1993: 58)", x: 58, width: 80, size: 9, gap: 19)
        // Back at the margin, after space, and unmatched to a font: once taken for a heading.
        add("In other words, the argument goes, and the question is, as always rather", x: 40, font: nil)
        add("more complicated than it looks from the outside, which is the point", x: 40)
        body(3)
        let blocks = LayoutAnalyzer().analyze(lines: lines).flatMap(\.blocks)
        XCTAssertFalse(blocks.contains { if case .heading = $0 { return true } else { return false } }, "\(blocks)")
        let quotes = blocks.compactMap { b -> String? in if case .quote(let runs) = b { return runs.joinedText } else { return nil } }
        XCTAssertEqual(quotes.count, 1, "\(blocks)")
        XCTAssertTrue(quotes.first?.hasPrefix("A long quotation") == true)
        XCTAssertTrue(quotes.first?.hasSuffix("ends here.\n(Somebody 1993: 58)") == true, "\(quotes)")
        XCTAssertTrue(blocks.contains { if case .paragraph(let runs, _) = $0 { return runs.joinedText.hasPrefix("In other words") } else { return false } })
    }

    /// A quotation's source at the foot of a page stays with the quotation,
    /// not with the paragraph that carries on over the page.
    func testSourceAtFootOfPageStaysWithQuote() {
        body(5)
        add("A long quotation that is set in from both margins and runs", x: 58, width: 310, size: 9, gap: 12)
        add("until it ends here.", x: 58, width: 100, size: 9, gap: 12)
        add("(Somebody 1993: 46)", x: 290, width: 80, size: 9, gap: 12)
        y = 60
        for i in 0..<6 {
            lines.append(TextLine(runs: [TextRun(text: "Next page text line \(i) that runs the whole way across")],
                                  page: 1, x: 40, y: y, width: 340, height: 11.5, fontSize: 10,
                                  pageWidth: 420, pageHeight: 595, fontName: "MinionPro"))
            y += 13
        }
        let blocks = LayoutAnalyzer().analyze(lines: lines).flatMap(\.blocks)
        let quotes = blocks.compactMap { b -> String? in if case .quote(let runs) = b { return runs.joinedText } else { return nil } }
        XCTAssertEqual(quotes.count, 1, "\(blocks)")
        XCTAssertTrue(quotes.first?.hasSuffix("(Somebody 1993: 46)") == true, "\(blocks)")
        XCTAssertTrue(blocks.contains { if case .paragraph(let runs, _) = $0 { return runs.joinedText.hasPrefix("Next page") } else { return false } }, "\(blocks)")
    }

    /// Bibliography entries: first line at the margin, the rest set in. Each
    /// entry is one paragraph, not a paragraph and a quotation.
    func testHangingIndentEntries() {
        body(5)
        for (k, entry) in ["Aaron", "Baker", "Cole"].enumerated() {
            add("\(entry), A. 1993. A Long Title of a Book That Runs All the Way Across the", x: 40)
            if k != 1 { add("Line, Continued Here. City: Publisher, which also runs across.", x: 52, width: 328) }
            add("Last line.", x: 52, width: 60)
        }
        let blocks = LayoutAnalyzer().analyze(lines: lines).flatMap(\.blocks)
        XCTAssertFalse(blocks.contains { if case .quote = $0 { return true } else { return false } }, "\(blocks)")
        let entries = blocks.compactMap { b -> String? in
            if case .paragraph(let runs, _) = b, runs.joinedText.contains(", A. 1993") { return runs.joinedText } else { return nil }
        }
        XCTAssertEqual(entries.count, 3, "\(blocks)")
        XCTAssertTrue(entries.allSatisfy { $0.hasSuffix("Last line.") }, "\(entries)")
    }

    /// A short line after a space that runs on into a lower-case line is the
    /// start of a paragraph, even in a bold or different font.
    func testLineRunningOnIsNotAHeading() {
        body(5)
        add("Section Like Opening Words", x: 40, width: 150, font: "Helvetica", gap: 13)
        add("carry on in lower case, so this is one paragraph after all.", x: 40)
        body(3)
        let blocks = LayoutAnalyzer().analyze(lines: lines).flatMap(\.blocks)
        XCTAssertFalse(blocks.contains { if case .heading = $0 { return true } else { return false } }, "\(blocks)")
    }
}

extension EPUBWriterTests {
    func testAnchorsInARowShareTheElementAfterThem() throws {
        #if canImport(Compression)
        throw XCTSkip("Entries are deflated on Apple platforms.")
        #else
        let book = Book(metadata: BookMetadata(title: "T", author: "A"), cover: nil, chapters: [
            Chapter(title: "One", blocks: [.paragraph([TextRun(text: "See"), TextRun(text: "1", superscript: true, link: .anchor("p4-1"))], indented: false)]),
            Chapter(title: "Notes", blocks: [.anchor("p4-1"), .anchor("en1-1"), .paragraph([TextRun(text: "1. The note.")], indented: false)]),
        ])
        let data = EPUBWriter().makeEPUB(book)
        let one = try XCTUnwrap(storedText(data, "OEBPS/text/ch001.xhtml"))
        let notes = try XCTUnwrap(storedText(data, "OEBPS/text/ch002.xhtml"))
        XCTAssertTrue(one.contains("href=\"ch002.xhtml#en1-1\""), one)
        XCTAssertTrue(notes.contains("<p id=\"en1-1\""), notes)
        XCTAssertFalse(notes.contains("<div id="), notes)
        #endif
    }
}
