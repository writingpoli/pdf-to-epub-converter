import Foundation

public struct LayoutOptions: Equatable {
    /// Drop running heads, running feet and page numbers.
    public var removeHeadersAndFooters = true
    /// Use the PDF's bookmarks to split chapters when it has them.
    public var useOutline = true
    /// Recognize headings from font size, bold text and words like "Chapter".
    public var detectHeadings = true
    /// Turn big vertical gaps and "* * *" lines into scene breaks.
    public var detectSceneBreaks = true
    /// Pages to leave out of the text flow (for example the cover page).
    public var skipPages: Set<Int> = []
    /// Title used when the book has no chapters of its own.
    public var fallbackTitle = "Untitled"

    public init() {}
}

/// Turns positioned lines of text into chapters of headings and paragraphs.
///
/// PDFs only know where glyphs sit on a page. Everything here is about guessing
/// the structure a reader expects back: which lines belong to one paragraph,
/// which words were hyphenated only because they hit the margin, what is a
/// heading, and what is page furniture (running heads, page numbers).
public struct LayoutAnalyzer {
    public var options: LayoutOptions

    public init(options: LayoutOptions = LayoutOptions()) {
        self.options = options
    }

    // MARK: - Entry point

    public func analyze(lines rawLines: [TextLine], pageImages: [PageImage] = [],
                        outline: [OutlineEntry] = []) -> [Chapter] {
        var lines = rawLines
            .filter { !options.skipPages.contains($0.page) }
            .map(Self.cleaned)
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        lines = Self.mergeFragments(lines)

        let bodySize = Self.bodyFontSize(lines)
        if options.removeHeadersAndFooters {
            lines = removeFurniture(lines, bodySize: bodySize,
                                    knownTitles: outline.map(\.title) + [options.fallbackTitle])
        }
        lines = Self.absorbDropCaps(lines, bodySize: bodySize)

        let metrics = PageMetrics(lines: lines, bodySize: bodySize)
        let images = pageImages.filter { !options.skipPages.contains($0.page) }
        let boundaries = options.useOutline ? (chapterEntries(outline) ?? []) : []
        var blocks = buildBlocks(lines: lines, images: images, metrics: metrics, boundaries: boundaries)
        Self.assignHeadingLevels(&blocks)
        return splitIntoChapters(blocks, outline: outline, bodySize: bodySize)
    }

    // MARK: - Cleanup

    static func cleaned(_ line: TextLine) -> TextLine {
        var line = line
        line.runs = line.runs.map { run in
            var run = run
            run.text = run.text
                .replacingOccurrences(of: "\u{FB00}", with: "ff")
                .replacingOccurrences(of: "\u{FB01}", with: "fi")
                .replacingOccurrences(of: "\u{FB02}", with: "fl")
                .replacingOccurrences(of: "\u{FB03}", with: "ffi")
                .replacingOccurrences(of: "\u{FB04}", with: "ffl")
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            return run
        }.filter { !$0.text.isEmpty }
        // Trim the outer whitespace of the line while keeping the run styling.
        if let first = line.runs.indices.first {
            line.runs[first].text = String(line.runs[first].text.drop(while: { $0 == " " }))
        }
        if let last = line.runs.indices.last {
            let t = line.runs[last].text
            line.runs[last].text = String(t[..<(t.lastIndex(where: { $0 != " " }).map { t.index(after: $0) } ?? t.startIndex)])
        }
        line.runs = line.runs.filter { !$0.text.isEmpty }
        return line
    }

    /// PDFKit sometimes hands back one visual line as several pieces. Glue pieces
    /// that share a baseline and sit close together horizontally.
    static func mergeFragments(_ lines: [TextLine]) -> [TextLine] {
        var result: [TextLine] = []
        let byPage = Dictionary(grouping: lines, by: \.page)
        for page in byPage.keys.sorted() {
            let pageLines = byPage[page]!.sorted { a, b in
                abs(a.y - b.y) < 0.5 * min(a.height, b.height) ? a.x < b.x : a.y < b.y
            }
            var merged: [TextLine] = []
            for line in pageLines {
                if var last = merged.last {
                    let centerA = last.y + last.height / 2
                    let centerB = line.y + line.height / 2
                    let sameBaseline = abs(centerA - centerB) < 0.35 * min(last.height, line.height)
                    let gap = line.x - last.maxX
                    let size = max(last.fontSize, line.fontSize)
                    if sameBaseline && gap > -0.5 * size && gap < 4 * size {
                        let needsSpace = gap > 0.15 * size
                            && !(last.text.hasSuffix(" ") || line.text.hasPrefix(" "))
                        if needsSpace { last.runs.append(TextRun(text: " ", bold: false, italic: false)) }
                        last.runs.append(contentsOf: line.runs)
                        let newMaxX = max(last.maxX, line.maxX)
                        let newMaxY = max(last.maxY, line.maxY)
                        last.y = min(last.y, line.y)
                        last.width = newMaxX - last.x
                        last.height = newMaxY - last.y
                        last.fontSize = max(last.fontSize, line.fontSize)
                        merged[merged.count - 1] = last
                        continue
                    }
                }
                merged.append(line)
            }
            result.append(contentsOf: merged)
        }
        return result
    }

    /// The font size most of the characters in the book are set in.
    static func bodyFontSize(_ lines: [TextLine]) -> Double {
        var histogram: [Double: Int] = [:]
        for line in lines {
            let size = (line.fontSize * 2).rounded() / 2
            histogram[size, default: 0] += line.text.count
        }
        return histogram.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key ?? 11
    }

    // MARK: - Running heads, feet and page numbers

    static let pageNumberPattern = try! NSRegularExpression(
        pattern: #"^[\s\-–—\[\]()|.]*(page\s*)?(\d{1,4}|[ivxlcdm]{1,7})[\s\-–—\[\]()|.]*$"#,
        options: [.caseInsensitive])

    static func furnitureKey(_ text: String) -> String {
        let lowered = text.lowercased()
        var key = ""
        var lastWasDigit = false
        for ch in lowered {
            if ch.isNumber {
                if !lastWasDigit { key.append("#") }
                lastWasDigit = true
            } else if !ch.isWhitespace {
                key.append(ch)
                lastWasDigit = false
            } else {
                lastWasDigit = false
            }
        }
        return key
    }

    static func isPageNumber(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return pageNumberPattern.firstMatch(in: text, range: range) != nil
    }

    func removeFurniture(_ lines: [TextLine], bodySize: Double, knownTitles: [String] = []) -> [TextLine] {
        let byPage = Dictionary(grouping: lines.indices, by: { lines[$0].page })
        var spacings: [Double] = []
        for (_, indices) in byPage {
            let sorted = indices.sorted { lines[$0].y < lines[$1].y }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                let d = lines[b].y - lines[a].y
                if d > bodySize * 0.6 && d < bodySize * 3 { spacings.append(d) }
            }
        }
        let spacing = PageMetrics.percentile(spacings, 0.5) ?? bodySize * 1.2

        // Titles that tend to be repeated as running heads: the book's, the
        // chapters' (from bookmarks), and anything set in heading-sized type.
        var titleKeys = Set(knownTitles.map(Self.furnitureKey))
        for line in lines where line.fontSize >= bodySize * 1.18 {
            titleKeys.insert(Self.furnitureKey(line.text))
        }
        titleKeys.remove("")

        var candidates: [Int: (key: String, isolated: Bool)] = [:]
        for (_, indices) in byPage {
            let sorted = indices.sorted { lines[$0].y < lines[$1].y }
            for (position, index) in sorted.enumerated() {
                guard position < 2 || position >= sorted.count - 2 else { continue }
                let line = lines[index]
                let inTopZone = line.maxY < line.pageHeight * 0.13
                let inBottomZone = line.y > line.pageHeight * 0.87
                guard inTopZone || inBottomZone else { continue }
                let neighbour = inTopZone
                    ? (position + 1 < sorted.count ? lines[sorted[position + 1]].y - line.y : .infinity)
                    : (position > 0 ? line.y - lines[sorted[position - 1]].y : .infinity)
                candidates[index] = (Self.furnitureKey(line.text), neighbour > spacing * 1.8 && sorted.count >= 5)
            }
        }
        var pagesPerKey: [String: Set<Int>] = [:]
        for (index, candidate) in candidates {
            pagesPerKey[candidate.key, default: []].insert(lines[index].page)
        }
        var drop = Set<Int>()
        for (index, candidate) in candidates {
            let line = lines[index]
            let small = line.fontSize <= bodySize * 1.1
            if Self.isPageNumber(line.text) {
                drop.insert(index)
            } else if small && pagesPerKey[candidate.key, default: []].count >= 3 {
                drop.insert(index)
            } else if candidate.isolated && line.fontSize < bodySize * 0.95
                        && pagesPerKey[candidate.key, default: []].count >= 2 {
                drop.insert(index)
            } else if small && candidate.isolated && titleKeys.contains(where: { key in
                key == candidate.key || (candidate.key.count >= 6 && key.contains(candidate.key))
                    || (key.count >= 6 && candidate.key.contains(key))
            }) {
                drop.insert(index)
            }
        }
        return lines.indices.filter { !drop.contains($0) }.map { lines[$0] }
    }

    // MARK: - Drop caps

    /// A big initial letter at the start of a chapter comes out as its own
    /// "line". Stick it back onto the word it belongs to.
    static func absorbDropCaps(_ lines: [TextLine], bodySize: Double) -> [TextLine] {
        var lines = lines
        var remove = Set<Int>()
        for (i, cap) in lines.enumerated() {
            let text = cap.text.trimmingCharacters(in: .whitespaces)
            guard text.count <= 2, text.contains(where: \.isLetter),
                  cap.fontSize >= bodySize * 1.6 else { continue }
            let beside = lines.indices.filter { j in
                j != i && lines[j].page == cap.page
                    && lines[j].y >= cap.y - cap.height * 0.5 && lines[j].y < cap.maxY
                    && lines[j].x >= cap.maxX - 1
                    && lines[j].fontSize < cap.fontSize
            }.sorted { lines[$0].y < lines[$1].y }
            guard let first = beside.first else { continue }
            lines[first].runs.insert(TextRun(text: text, bold: cap.runs.first?.bold ?? false,
                                             italic: cap.runs.first?.italic ?? false), at: 0)
            for j in beside {
                let shift = lines[j].x - cap.x
                lines[j].x = cap.x
                lines[j].width += shift
            }
            remove.insert(i)
        }
        return lines.indices.filter { !remove.contains($0) }.map { lines[$0] }
    }

    // MARK: - Page geometry

    struct PageMetrics {
        var bodySize: Double
        var lineSpacing: Double
        var leftMargin: [Int: Double] = [:]
        var rightEdge: [Int: Double] = [:]
        var usesIndents = false
        var usesGaps = false

        init(lines: [TextLine], bodySize: Double) {
            self.bodySize = bodySize
            let body = lines.filter { abs($0.fontSize - bodySize) <= max(0.6, bodySize * 0.08) }

            var deltas: [Double] = []
            for (a, b) in zip(body, body.dropFirst()) where a.page == b.page {
                let d = b.y - a.y
                if d > bodySize * 0.6 && d < bodySize * 3 { deltas.append(d) }
            }
            lineSpacing = Self.percentile(deltas, 0.5) ?? bodySize * 1.2

            for (page, pageLines) in Dictionary(grouping: body, by: \.page) {
                var counts: [Double: Int] = [:]
                for line in pageLines { counts[line.x.rounded(), default: 0] += 1 }
                let minX = pageLines.map(\.x).min() ?? 0
                if let (x, count) = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
                   count >= 3 {
                    leftMargin[page] = x
                } else {
                    leftMargin[page] = minX
                }
                rightEdge[page] = Self.percentile(pageLines.map(\.maxX), 0.9) ?? pageLines.map(\.maxX).max() ?? 0
            }
            // Pages with only big text (a chapter opener) borrow their neighbours' margins.
            let fallbackLeft = Self.percentile(Array(leftMargin.values), 0.5) ?? 0
            let fallbackRight = Self.percentile(Array(rightEdge.values), 0.5) ?? 0
            for page in Set(lines.map(\.page)) {
                if leftMargin[page] == nil { leftMargin[page] = fallbackLeft }
                if rightEdge[page] == nil { rightEdge[page] = fallbackRight }
            }

            var indented = 0
            var gapped = 0
            for (a, b) in zip(body, body.dropFirst()) {
                let offset = b.x - (leftMargin[b.page] ?? 0)
                let previousOffset = a.x - (leftMargin[a.page] ?? 0)
                if offset > bodySize * 0.6 && offset < bodySize * 6 && abs(previousOffset) < bodySize * 0.4 {
                    indented += 1
                }
                if a.page == b.page && b.y - a.y > lineSpacing * 1.4 { gapped += 1 }
            }
            let threshold = max(3, body.count / 50)
            usesIndents = indented >= threshold
            usesGaps = gapped >= threshold
        }

        static func percentile(_ values: [Double], _ p: Double) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
            return sorted[index]
        }

        func indent(of line: TextLine) -> Double {
            line.x - (leftMargin[line.page] ?? line.x)
        }

        func columnWidth(page: Int) -> Double {
            max(1, (rightEdge[page] ?? 0) - (leftMargin[page] ?? 0))
        }

        /// The line stops well before the right margin.
        func isShort(_ line: TextLine, slack: Double) -> Bool {
            line.maxX < (rightEdge[line.page] ?? line.maxX) - slack
        }
    }

    // MARK: - Blocks

    struct PositionedBlock {
        var block: Block
        var page: Int
        var y: Double
        /// For headings: the size used to rank heading levels.
        var headingSize: Double?
    }

    static let sceneBreakPattern = try! NSRegularExpression(
        pattern: #"^[\s*·•∙~#◆◇❖⁂§†✦✧●○—–\-_=]{1,20}$"#)

    static let chapterWordPattern = try! NSRegularExpression(
        pattern: #"^(chapter|part|book|prologue|epilogue|introduction|preface|foreword|afterword|acknowledg(e)?ments?|appendix|interlude|contents|table of contents|notes|bibliography|index|dedication|about the author)\b"#,
        options: [.caseInsensitive])

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static let terminalPunctuation: Set<Character> = [".", "!", "?", "…", ":", "\"", "”", "’", "'", ")", "]", "»"]

    func buildBlocks(lines: [TextLine], images: [PageImage], metrics m: PageMetrics,
                     boundaries: [OutlineEntry] = []) -> [PositionedBlock] {
        let hyphenatedWords = Self.hyphenatedWords(in: lines)
        let imagesByPage = Dictionary(grouping: images, by: \.page)
        let linesByPage = Dictionary(grouping: lines, by: \.page)
        let pages = Set(lines.map(\.page)).union(images.map(\.page)).sorted()

        var blocks: [PositionedBlock] = []
        var paragraph: [TextRun] = []
        var paragraphIndented = false
        var paragraphStart: (page: Int, y: Double) = (0, 0)
        var previous: TextLine?          // previous line of the open paragraph
        var previousAny: TextLine?       // previous line of any kind
        var paragraphIsBlockLines = false

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(PositionedBlock(block: .paragraph(Self.compact(paragraph), indented: paragraphIndented),
                                              page: paragraphStart.page, y: paragraphStart.y))
            }
            paragraph = []
            previous = nil
            paragraphIsBlockLines = false
        }

        let body = m.bodySize
        let spacing = m.lineSpacing

        for page in pages {
            for image in imagesByPage[page] ?? [] {
                flush()
                previousAny = nil
                blocks.append(PositionedBlock(block: .image(image.image, alt: image.altText), page: page, y: 0))
            }
            let pageLines = linesByPage[page] ?? []
            for (index, line) in pageLines.enumerated() {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                let gapBefore: Double = {
                    guard let p = previousAny, p.page == line.page else { return .infinity }
                    return line.y - p.y
                }()
                let gapAfter: Double = {
                    guard index + 1 < pageLines.count else { return .infinity }
                    return pageLines[index + 1].y - line.y
                }()
                defer { previousAny = line }

                // Scene break markers such as "* * *".
                if text.count <= 20, Self.matches(Self.sceneBreakPattern, text), !text.contains(where: \.isLetter) {
                    flush()
                    if options.detectSceneBreaks, let last = blocks.last, case .paragraph = last.block {
                        blocks.append(PositionedBlock(block: .sceneBreak, page: page, y: line.y))
                    }
                    continue
                }

                if options.detectHeadings, let size = headingSize(line, text: text, gapBefore: gapBefore,
                                                                    gapAfter: gapAfter, metrics: m) {
                    flush()
                    if var last = blocks.last, let lastSize = last.headingSize, abs(lastSize - size) < 0.6,
                       last.page == page, case .heading(let level, let runs) = last.block,
                       gapBefore < max(line.fontSize, body) * 2.4 {
                        let plain = line.runs.map { TextRun(text: $0.text, italic: $0.italic) }
                        last.block = .heading(level: level, runs: Self.compact(runs + [TextRun(text: " ")] + plain))
                        blocks[blocks.count - 1] = last
                    } else {
                        blocks.append(PositionedBlock(block: .heading(level: 1, runs: line.runs.map { TextRun(text: $0.text, italic: $0.italic) }),
                                                      page: page, y: line.y, headingSize: size))
                    }
                    continue
                }

                // Body text: does this line continue the open paragraph?
                var startsNew = true
                var joinWithBreak = false
                if let p = previous, Self.boundary(in: boundaries, from: p, to: line, bodySize: body) {
                    startsNew = true
                } else if let p = previous {
                    startsNew = false
                    let colWidth = m.columnWidth(page: p.page)
                    let pShortHard = m.isShort(p, slack: max(body * 3, colWidth * 0.18))
                    let pEndsSentence = p.text.last.map { Self.terminalPunctuation.contains($0) } ?? false
                    let lIndent = m.indent(of: line)
                    let pIndent = m.indent(of: p)
                    let lIndented = lIndent > body * 0.6
                    let pIndented = pIndent > body * 0.6

                    if p.page == line.page {
                        let gap = line.y - p.y
                        if gap > spacing * 1.4 {
                            startsNew = true
                            let sceneGap = spacing * (m.usesGaps ? 3.2 : 2.4)
                            if options.detectSceneBreaks && gap > sceneGap {
                                flush()
                                blocks.append(PositionedBlock(block: .sceneBreak, page: page, y: p.maxY))
                            }
                        } else if lIndented && (!pIndented || lIndent > pIndent + body * 0.6) && m.usesIndents {
                            startsNew = true
                        } else if lIndented && pIndented && abs(lIndent - pIndent) < body * 0.6 {
                            // Two lines at the same indent: a block quote continues, a run
                            // of short lines (dialogue, verse) are separate paragraphs.
                            if pShortHard && m.usesIndents && !paragraphIsBlockLines {
                                startsNew = true
                            } else if pShortHard {
                                joinWithBreak = true
                            }
                        } else if !m.usesIndents && !m.usesGaps
                                    && m.isShort(p, slack: body * 1.5) && pEndsSentence {
                            startsNew = true
                        }
                    } else {
                        // Page turn. Carry on unless the new page clearly opens a paragraph.
                        let startsLower = line.text.first?.isLowercase ?? false
                        if m.usesIndents && lIndented && !startsLower {
                            startsNew = true
                        } else if pEndsSentence && m.isShort(p, slack: body * 1.5) && !startsLower {
                            startsNew = true
                        }
                    }
                }

                if startsNew {
                    flush()
                    paragraph = line.runs
                    paragraphIndented = m.indent(of: line) > body * 0.6
                    paragraphStart = (line.page, line.y)
                    previous = line
                    paragraphIsBlockLines = false
                    continue
                }

                if joinWithBreak {
                    paragraph.append(TextRun(text: "\n"))
                    paragraph.append(contentsOf: line.runs)
                    paragraphIsBlockLines = true
                } else {
                    Self.join(&paragraph, with: line.runs, hyphenatedWords: hyphenatedWords)
                }
                previous = line
            }
        }
        flush()
        return blocks
    }

    /// Whether a bookmark points somewhere between two consecutive lines, in
    /// which case they can't share a paragraph: they're in different chapters.
    static func boundary(in entries: [OutlineEntry], from a: TextLine, to b: TextLine, bodySize: Double) -> Bool {
        entries.contains { entry in
            let position = (entry.page, (entry.y ?? -1) - bodySize)
            return (a.page, a.y) < position && position <= (b.page, b.y)
        }
    }

    /// Returns a ranking size when the line looks like a heading.
    func headingSize(_ line: TextLine, text: String, gapBefore: Double, gapAfter: Double,
                     metrics m: PageMetrics) -> Double? {
        let body = m.bodySize
        guard text.count <= 160, text.contains(where: \.isLetter) else { return nil }
        if line.fontSize >= body * 1.18 {
            return line.fontSize
        }
        let isolatedAbove = gapBefore > m.lineSpacing * 1.8
        let isolatedBelow = gapAfter > m.lineSpacing * 1.6
        if text.count <= 60, isolatedAbove, isolatedBelow || gapAfter == .infinity,
           Self.matches(Self.chapterWordPattern, text) {
            return max(line.fontSize, body * 1.5)
        }
        if line.isBold, text.count <= 90, isolatedAbove, isolatedBelow,
           let last = text.last, !".,;".contains(last) {
            return body * 1.1
        }
        return nil
    }

    /// Hyphenated words that appear in the middle of a line somewhere in the
    /// book. Those keep their hyphen when split across lines ("well-known").
    static func hyphenatedWords(in lines: [TextLine]) -> Set<String> {
        var words = Set<String>()
        for line in lines {
            for token in line.text.split(separator: " ") where token.contains("-") {
                let word = token.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-")))
                if word.first?.isLetter == true && word.last?.isLetter == true {
                    words.insert(word.lowercased())
                }
            }
        }
        return words
    }

    static func join(_ paragraph: inout [TextRun], with runs: [TextRun], hyphenatedWords: Set<String>) {
        guard !runs.isEmpty else { return }
        guard let lastIndex = paragraph.indices.last else {
            paragraph = runs
            return
        }
        let tail = paragraph[lastIndex].text
        let nextText = runs.map(\.text).joined()
        let nextStartsLower = nextText.first?.isLowercase ?? false

        if tail.hasSuffix("\u{00AD}") || tail.hasSuffix("¬") {
            paragraph[lastIndex].text.removeLast()
            paragraph.append(contentsOf: runs)
        } else if tail.hasSuffix("-"), !tail.hasSuffix("--"),
                  tail.dropLast().last?.isLetter == true, nextStartsLower {
            let before = paragraph.map(\.text).joined()
            let lastWord = before.split(separator: " ").last.map(String.init) ?? ""
            let nextWord = nextText.split(separator: " ").first.map(String.init) ?? ""
            let candidate = (lastWord + nextWord)
                .trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-")))
                .lowercased()
            if !hyphenatedWords.contains(candidate) {
                paragraph[lastIndex].text.removeLast()
            }
            paragraph.append(contentsOf: runs)
        } else if tail.hasSuffix("—") || tail.hasSuffix("–") || tail.hasSuffix("/") || tail.hasSuffix(" ")
                    || nextText.hasPrefix("—") {
            paragraph.append(contentsOf: runs)
        } else {
            paragraph.append(TextRun(text: " "))
            paragraph.append(contentsOf: runs)
        }
    }

    /// Merges neighbouring runs with the same style and tidies whitespace.
    static func compact(_ runs: [TextRun]) -> [TextRun] {
        var result: [TextRun] = []
        for run in runs where !run.text.isEmpty {
            // A plain space between two runs of the same style shouldn't split them.
            if let last = result.last, last.bold == run.bold, last.italic == run.italic {
                result[result.count - 1].text += run.text
            } else if run.text.allSatisfy({ $0 == " " }), !result.isEmpty {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        for i in result.indices {
            var text = result[i].text
            while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
            text = text.replacingOccurrences(of: " \n", with: "\n").replacingOccurrences(of: "\n ", with: "\n")
            result[i].text = text
        }
        if let first = result.indices.first {
            result[first].text = String(result[first].text.drop(while: \.isWhitespace))
        }
        if let last = result.indices.last {
            while result[last].text.last?.isWhitespace == true { result[last].text.removeLast() }
        }
        return result.filter { !$0.text.isEmpty }
    }

    /// Ranks heading sizes: the largest becomes level 1, the next level 2, and so on.
    static func assignHeadingLevels(_ blocks: inout [PositionedBlock]) {
        let sizes = blocks.compactMap(\.headingSize).sorted(by: >)
        var clusters: [Double] = []
        for size in sizes where clusters.last.map({ $0 - size > 0.6 }) ?? true {
            clusters.append(size)
        }
        for i in blocks.indices {
            guard let size = blocks[i].headingSize, case .heading(_, let runs) = blocks[i].block else { continue }
            let rank = clusters.firstIndex(where: { abs($0 - size) <= 0.6 }) ?? 0
            blocks[i].block = .heading(level: min(3, rank + 1), runs: runs)
        }
    }

    // MARK: - Chapters

    func splitIntoChapters(_ blocks: [PositionedBlock], outline: [OutlineEntry], bodySize: Double) -> [Chapter] {
        guard !blocks.isEmpty else { return [] }

        var chapters: [Chapter]
        if options.useOutline, let entries = chapterEntries(outline), entries.count >= 2 {
            chapters = splitByOutline(blocks, entries: entries, bodySize: bodySize)
        } else if options.detectHeadings, let split = splitByHeadings(blocks) {
            chapters = split
        } else {
            chapters = splitByPages(blocks)
        }
        chapters = chapters.filter { !$0.blocks.isEmpty }
        for i in chapters.indices where chapters[i].title.trimmingCharacters(in: .whitespaces).isEmpty {
            chapters[i].title = "Section \(i + 1)"
        }
        return chapters
    }

    func chapterEntries(_ outline: [OutlineEntry]) -> [OutlineEntry]? {
        guard !outline.isEmpty else { return nil }
        let minLevel = outline.map(\.level).min() ?? 0
        var entries = outline.filter { $0.level == minLevel }
        // A single root bookmark ("My Book") wrapping the real chapters.
        if entries.count < 2 {
            entries = outline.filter { $0.level <= minLevel + 1 }
        }
        entries = entries.sorted { ($0.page, $0.y ?? -1) < ($1.page, $1.y ?? -1) }
        var unique: [OutlineEntry] = []
        for entry in entries where !unique.contains(where: { $0.page == entry.page && $0.y == entry.y }) {
            unique.append(entry)
        }
        return unique
    }

    func splitByOutline(_ blocks: [PositionedBlock], entries: [OutlineEntry], bodySize: Double) -> [Chapter] {
        var front = Chapter(title: "", blocks: [])
        var chapters = entries.map { Chapter(title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines), blocks: []) }
        for block in blocks {
            let index = entries.lastIndex { entry in
                if block.page != entry.page { return block.page > entry.page }
                guard let y = entry.y else { return true }
                return block.y >= y - bodySize
            }
            if let index {
                chapters[index].blocks.append(block.block)
            } else {
                front.blocks.append(block.block)
            }
        }
        if !front.blocks.isEmpty {
            front.title = Self.firstHeadingText(front.blocks) ?? "Front Matter"
            chapters.insert(front, at: 0)
        }
        return chapters
    }

    func splitByHeadings(_ blocks: [PositionedBlock]) -> [Chapter]? {
        let levels = blocks.compactMap { b -> Int? in
            if case .heading(let level, _) = b.block { return level }
            return nil
        }
        guard let splitLevel = (1...3).first(where: { level in levels.filter { $0 <= level }.count >= 2 }) else {
            return nil
        }
        var chapters: [Chapter] = []
        var current = Chapter(title: "", blocks: [])
        var i = 0
        while i < blocks.count {
            // A run of consecutive headings ("Chapter One" / "The Beginning") opens one chapter.
            var j = i
            var group: [Block] = []
            var containsSplit = false
            while j < blocks.count, case .heading(let level, _) = blocks[j].block {
                group.append(blocks[j].block)
                if level <= splitLevel { containsSplit = true }
                j += 1
            }
            if group.isEmpty {
                current.blocks.append(blocks[i].block)
                i += 1
                continue
            }
            if containsSplit {
                if !current.blocks.isEmpty {
                    if current.title.isEmpty { current.title = Self.firstHeadingText(current.blocks) ?? "Front Matter" }
                    chapters.append(current)
                }
                let title = group.compactMap(Self.headingText).reduce("") { title, part in
                    guard let last = title.last else { return part }
                    return title + (".:;!?—".contains(last) ? " " : ": ") + part
                }
                current = Chapter(title: String(title.prefix(120)), blocks: group)
            } else {
                current.blocks.append(contentsOf: group)
            }
            i = j
        }
        if !current.blocks.isEmpty {
            if current.title.isEmpty { current.title = Self.firstHeadingText(current.blocks) ?? "Front Matter" }
            chapters.append(current)
        }
        return chapters
    }

    func splitByPages(_ blocks: [PositionedBlock]) -> [Chapter] {
        let pagesPerSection = 20
        let lastPage = blocks.map(\.page).max() ?? 0
        if lastPage < pagesPerSection * 2 {
            return [Chapter(title: options.fallbackTitle, blocks: blocks.map(\.block))]
        }
        var chapters: [Chapter] = []
        var current: [PositionedBlock] = []
        for block in blocks {
            if let first = current.first, block.page - first.page >= pagesPerSection {
                chapters.append(Chapter(title: "Pages \(first.page + 1)–\(current.last!.page + 1)",
                                        blocks: current.map(\.block)))
                current = []
            }
            current.append(block)
        }
        if let first = current.first {
            chapters.append(Chapter(title: "Pages \(first.page + 1)–\(current.last!.page + 1)",
                                    blocks: current.map(\.block)))
        }
        return chapters
    }

    static func headingText(_ block: Block) -> String? {
        guard case .heading(_, let runs) = block else { return nil }
        return runs.map(\.text).joined().replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func firstHeadingText(_ blocks: [Block]) -> String? {
        blocks.lazy.compactMap(headingText).first
    }
}
