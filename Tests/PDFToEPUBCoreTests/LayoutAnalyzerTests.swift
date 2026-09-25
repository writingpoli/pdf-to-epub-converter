import XCTest
@testable import PDFToEPUBCore

/// Builds pages of lines the way PDFKit reports them, for layout tests.
struct PageBuilder {
    var page: Int
    var lines: [TextLine] = []
    var y: Double = 60
    let left: Double = 50
    let width: Double = 320
    let size: Double = 11
    let leading: Double = 14

    init(page: Int) { self.page = page }

    mutating func line(_ text: String, indent: Double = 0, width: Double? = nil, size: Double? = nil,
                       italic: Bool = false, bold: Bool = false, at y: Double? = nil, advance: Double? = nil) {
        let fontSize = size ?? self.size
        if let y { self.y = y }
        lines.append(TextLine(runs: [TextRun(text: text, bold: bold, italic: italic)], page: page,
                              x: left + indent, y: self.y,
                              width: width ?? (self.width - indent), height: fontSize * 1.15,
                              fontSize: fontSize, pageWidth: 420, pageHeight: 595))
        self.y += advance ?? leading
    }

    mutating func gap(_ amount: Double) { y += amount }

    /// Adds a running head and a page number like a printed book.
    mutating func furniture(head: String) {
        lines.append(TextLine(runs: [TextRun(text: head, italic: true)], page: page, x: 150, y: 30, width: 120,
                              height: 10, fontSize: 9, pageWidth: 420, pageHeight: 595))
        lines.append(TextLine(runs: [TextRun(text: "\(page + 1)")], page: page, x: 205, y: 555, width: 10,
                              height: 10, fontSize: 9, pageWidth: 420, pageHeight: 595))
    }
}

final class LayoutAnalyzerTests: XCTestCase {
    func paragraphs(_ chapters: [Chapter]) -> [String] {
        chapters.flatMap(\.blocks).compactMap { block in
            if case .paragraph(let runs, _) = block { return runs.map(\.text).joined() }
            return nil
        }
    }

    func headings(_ chapters: [Chapter]) -> [String] {
        chapters.flatMap(\.blocks).compactMap { block in
            if case .heading(_, let runs) = block { return runs.map(\.text).joined() }
            return nil
        }
    }

    /// A few pages of an indented, justified book with running heads.
    func sampleBook() -> [TextLine] {
        var lines: [TextLine] = []
        for page in 0..<4 {
            var p = PageBuilder(page: page)
            p.furniture(head: page % 2 == 0 ? "The Sample Book" : "A Chapter Title")
            if page == 0 || page == 2 {
                p.line("Chapter \(page == 0 ? "One" : "Two")", width: 120, size: 20, advance: 40)
            }
            p.line("The first paragraph of the chapter starts at the margin and runs", width: 320)
            p.line("across several lines until it reaches a hyphen-", width: 320)
            p.line("ated word that needs to be joined back together.", width: 250)
            p.line("A second paragraph starts with an indent and has a", indent: 16)
            p.line("compound well-known word that keeps its hyphen, like well-", width: 320)
            p.line("known here, and it carries on over the page break so that", width: 320)
            lines += p.lines
        }
        return lines
    }

    func testRemovesRunningHeadsAndPageNumbers() {
        let chapters = LayoutAnalyzer().analyze(lines: sampleBook())
        let text = paragraphs(chapters).joined(separator: "\n")
        XCTAssertFalse(text.contains("The Sample Book"))
        XCTAssertFalse(text.contains("A Chapter Title"))
        XCTAssertNil(text.range(of: #"\b[1-4]\b"#, options: .regularExpression))
    }

    func testJoinsHyphenatedWordsButKeepsCompounds() {
        let text = paragraphs(LayoutAnalyzer().analyze(lines: sampleBook())).joined(separator: "\n")
        XCTAssertTrue(text.contains("hyphenated word"), text)
        XCTAssertTrue(text.contains("like well-known here"), text)
    }

    func testSplitsChaptersAtHeadings() {
        let chapters = LayoutAnalyzer().analyze(lines: sampleBook())
        XCTAssertEqual(chapters.map(\.title), ["Chapter One", "Chapter Two"])
    }

    func testParagraphContinuesAcrossPageTurn() {
        let chapters = LayoutAnalyzer().analyze(lines: sampleBook())
        let text = paragraphs(chapters)
        // Page 1 has no heading, so its first line continues the paragraph from page 0.
        XCTAssertTrue(text.contains { $0.contains("so that The first paragraph") }, text.joined(separator: "\n"))
    }

    func testIndentStartsNewParagraph() {
        let text = paragraphs(LayoutAnalyzer().analyze(lines: sampleBook()))
        XCTAssertTrue(text.contains { $0.hasPrefix("A second paragraph starts") })
    }

    func testUsesOutlineForChapters() {
        var lines: [TextLine] = []
        for page in 0..<3 {
            var p = PageBuilder(page: page)
            for i in 0..<10 { p.line("Line \(i) of page \(page) with enough words to fill the measure.", indent: i == 0 ? 16 : 0) }
            lines += p.lines
        }
        let outline = [OutlineEntry(title: "Opening", page: 0), OutlineEntry(title: "Middle", page: 1, y: 100)]
        let chapters = LayoutAnalyzer().analyze(lines: lines, outline: outline)
        XCTAssertEqual(chapters.map(\.title), ["Opening", "Middle"])
        guard chapters.count == 2 else { return }
        XCTAssertTrue(paragraphs([chapters[1]]).first?.hasPrefix("Line 3 of page 1") ?? false,
                      paragraphs([chapters[1]]).joined(separator: "\n"))
    }

    func testSceneBreakMarker() {
        var p = PageBuilder(page: 0)
        for i in 0..<6 { p.line("Some sentence number \(i) in the first scene of the story.", indent: i % 3 == 0 ? 16 : 0) }
        p.line("*  *  *", indent: 140, width: 30)
        for i in 0..<6 { p.line("Another sentence number \(i) in the second scene here.", indent: i % 3 == 0 ? 16 : 0) }
        let blocks = LayoutAnalyzer().analyze(lines: p.lines).flatMap(\.blocks)
        XCTAssertTrue(blocks.contains(.sceneBreak))
    }

    func testDropCapIsReattached() {
        var p = PageBuilder(page: 0)
        p.line("Chapter One", width: 120, size: 20, advance: 40)
        let top = p.y
        p.lines.append(TextLine(runs: [TextRun(text: "T")], page: 0, x: 50, y: top, width: 26, height: 34,
                                fontSize: 36, pageWidth: 420, pageHeight: 595))
        p.line("he story begins with a large initial letter that", indent: 30)
        p.line("spans two lines of text at the start of the chapter.", indent: 30)
        p.line("After that the text runs at the normal margin again", width: 320)
        p.line("for the rest of the paragraph.", width: 150)
        let text = paragraphs(LayoutAnalyzer().analyze(lines: p.lines))
        XCTAssertEqual(text.first?.hasPrefix("The story begins"), true, text.joined(separator: "\n"))
        XCTAssertEqual(text.count, 1, text.joined(separator: "\n"))
    }

    func testBlockStyleParagraphsSeparatedByGaps() {
        var p = PageBuilder(page: 0)
        for paragraph in 0..<4 {
            p.line("Block style paragraph \(paragraph) starts at the margin with no", width: 320)
            p.line("indent at all and ends on this short line.", width: 200)
            p.gap(10)
        }
        XCTAssertEqual(paragraphs(LayoutAnalyzer().analyze(lines: p.lines)).count, 4)
    }

    func testMergesSplitFragmentsOnOneBaseline() {
        let a = TextLine(runs: [TextRun(text: "Hello")], page: 0, x: 50, y: 100, width: 30, height: 12,
                         fontSize: 11, pageWidth: 420, pageHeight: 595)
        let b = TextLine(runs: [TextRun(text: "world", italic: true)], page: 0, x: 84, y: 100.5, width: 30, height: 12,
                         fontSize: 11, pageWidth: 420, pageHeight: 595)
        let merged = LayoutAnalyzer.mergeFragments([b, a])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.text, "Hello world")
    }

    func testPageNumberPattern() {
        for text in ["12", "- 12 -", "xiv", "Page 3", "[7]"] { XCTAssertTrue(LayoutAnalyzer.isPageNumber(text), text) }
        for text in ["Chapter 12", "I went home.", "12 Angry Men"] { XCTAssertFalse(LayoutAnalyzer.isPageNumber(text), text) }
    }
}
