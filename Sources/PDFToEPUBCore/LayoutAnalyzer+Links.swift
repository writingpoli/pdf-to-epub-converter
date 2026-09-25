import Foundation

/// Links: note references to their notes, contents entries to their chapters,
/// and the PDF's own links to the right spot in the book.
extension LayoutAnalyzer {

    // MARK: - Footnotes

    struct Footnote {
        var page: Int
        var id: String
        var refID: String
        var marker: String
        var runs: [TextRun]
        var referenced = false
    }

    static let noteMarkerPattern = try! NSRegularExpression(
        pattern: #"^(\d{1,3}|[*†‡§¶]{1,3})(?:[.)]\s*|\s+|(?=\p{Lu}))"#)
    static let markerTextPattern = try! NSRegularExpression(pattern: #"^(\d{1,3}|[*†‡§¶]{1,3})$"#)

    /// The note number or symbol at the start of a note, and the runs after it.
    static func noteMarker(_ runs: [TextRun]) -> (marker: String, rest: [TextRun])? {
        if let first = runs.first, first.superscript {
            let marker = first.text.trimmingCharacters(in: .whitespaces)
            if matches(markerTextPattern, marker) {
                return (marker, compact(Array(runs.dropFirst())))
            }
        }
        let text = runs.joinedText
        guard let match = noteMarkerPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text), let group = Range(match.range(at: 1), in: text)
        else { return nil }
        var rest = runs
        rest.modify(characters: 0..<text.distance(from: text.startIndex, to: whole.upperBound)) { $0.text = "" }
        return (String(text[group]), compact(rest))
    }

    /// Takes footnotes (small type at the foot of a page, starting with a
    /// number or symbol) out of the text flow, and links each one to the
    /// superscript reference on its page.
    static func separateFootnotes(_ lines: [TextLine], bodySize: Double) -> ([TextLine], [Footnote]) {
        var kept: [TextLine] = []
        var notes: [Footnote] = []
        let byPage = Dictionary(grouping: lines, by: \.page)
        for page in byPage.keys.sorted() {
            let pageLines = byPage[page]!
            guard let lastBody = pageLines.lastIndex(where: { $0.fontSize >= bodySize * 0.93 }),
                  lastBody + 1 < pageLines.count else {
                kept += pageLines
                continue
            }
            let tail = pageLines[(lastBody + 1)...]
            let first = tail.first!
            let continuesPreviousNote = notes.last?.page == page - 1
            guard tail.allSatisfy({ $0.fontSize <= bodySize * 0.9 }), first.y > first.pageHeight * 0.45,
                  noteMarker(first.runs) != nil || continuesPreviousNote else {
                kept += pageLines
                continue
            }

            var body = Array(pageLines[...lastBody])
            var pageNotes: [Footnote] = []
            for line in tail {
                if let (marker, rest) = noteMarker(line.runs) {
                    let n = pageNotes.count + 1
                    pageNotes.append(Footnote(page: page, id: "fn\(page + 1)-\(n)", refID: "fnref\(page + 1)-\(n)",
                                              marker: marker, runs: rest))
                } else if !pageNotes.isEmpty {
                    join(&pageNotes[pageNotes.count - 1].runs, with: line.runs, hyphenatedWords: [])
                } else if !notes.isEmpty {
                    // A long note carried over from the page before.
                    join(&notes[notes.count - 1].runs, with: line.runs, hyphenatedWords: [])
                }
            }

            // Link each note to the first unused reference with the same marker.
            for n in pageNotes.indices {
                search: for l in body.indices {
                    for r in body[l].runs.indices {
                        let run = body[l].runs[r]
                        // The PDF may already link the marker to the foot of this page.
                        var linksHere = run.link == nil
                        if case .page(let target, _) = run.link, target == page { linksHere = true }
                        guard run.superscript, linksHere,
                              run.text.trimmingCharacters(in: .whitespaces) == pageNotes[n].marker else { continue }
                        body[l].runs[r].link = .anchor(pageNotes[n].id)
                        body[l].runs[r].id = pageNotes[n].refID
                        pageNotes[n].referenced = true
                        break search
                    }
                }
            }
            kept += body
            notes += pageNotes
        }
        return (kept, notes)
    }

    /// Puts each footnote after the text of its page. Chapters later move
    /// them to their end.
    static func insertFootnotes(_ notes: [Footnote], into blocks: [PositionedBlock]) -> [PositionedBlock] {
        guard !notes.isEmpty else { return blocks }
        func block(_ note: Footnote) -> PositionedBlock {
            let back = TextRun(text: note.marker, link: note.referenced ? .anchor(note.refID) : nil)
            let runs = compact([back, TextRun(text: " ")] + note.runs)
            return PositionedBlock(block: .footnote(id: note.id, runs: runs), page: note.page,
                                   y: .greatestFiniteMagnitude)
        }
        var result: [PositionedBlock] = []
        var pending = notes[...]
        for b in blocks {
            while let note = pending.first, note.page < b.page {
                result.append(block(note))
                pending.removeFirst()
            }
            result.append(b)
        }
        result += pending.map(block)
        return result
    }

    // MARK: - Printed contents pages

    static let contentsTitlePattern = try! NSRegularExpression(
        pattern: #"^\s*(table of )?contents\s*$"#, options: [.caseInsensitive])
    /// "Chapter One ........ 12", "Prologue  1", "Preface … ix"
    static let contentsEntryPattern = try! NSRegularExpression(
        pattern: #"^(.*?[^\s.·•…_])(?:\s*[.·•…_](?:\s*[.·•…_])+\s*|\s+)(\d{1,4}|[ivxlcdm]{1,7})\s*$"#)

    static func contentsEntry(_ line: TextLine) -> (runs: [TextRun], pageNumber: String)? {
        let text = line.text
        guard let match = contentsEntryPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let title = Range(match.range(at: 1), in: text), let number = Range(match.range(at: 2), in: text)
        else { return nil }
        let keep = text.distance(from: text.startIndex, to: title.upperBound)
        var runs = line.runs
        runs.modify(characters: keep..<text.count) { $0.text = "" }
        return (compact(runs), String(text[number]))
    }

    /// Pages that look like a printed table of contents: mostly lines ending
    /// in page numbers, near the front or under a "Contents" title.
    static func contentsPages(_ lines: [TextLine]) -> Set<Int> {
        let byPage = Dictionary(grouping: lines, by: \.page)
        let lastPage = byPage.keys.max() ?? 0
        var pages = Set<Int>()
        for page in byPage.keys.sorted() {
            let pageLines = byPage[page]!
            let entries = pageLines.filter { contentsEntry($0) != nil }.count
            guard entries >= 3, Double(entries) >= Double(pageLines.count) * 0.4 else { continue }
            let titled = pageLines.contains { matches(contentsTitlePattern, $0.text) }
            if titled || pages.contains(page - 1) || page <= max(12, lastPage * 15 / 100) {
                pages.insert(page)
            }
        }
        return pages
    }

    /// Letters and digits only, lowercased, without accents: for matching
    /// titles written slightly differently.
    static func matchKey(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func linkContentsEntries(_ blocks: inout [PositionedBlock], outline: [OutlineEntry],
                                    printedPageNumbers: [Int: String]) {
        let entries = blocks.indices.filter { blocks[$0].isContentsEntry }
        guard let lastEntry = entries.last else { return }

        // Headings after the contents, alone and as runs of consecutive headings
        // ("Chapter One" + "The Beginning"), each pointing at the run's start.
        var headings: [(key: String, index: Int)] = []
        var i = lastEntry + 1
        while i < blocks.count {
            guard blocks[i].headingSize != nil else { i += 1; continue }
            let start = i
            var groupText = ""
            while i < blocks.count, blocks[i].headingSize != nil, let text = headingText(blocks[i].block) {
                headings.append((matchKey(text), start))
                groupText += " " + text
                i += 1
            }
            headings.append((matchKey(groupText), start))
        }
        let outlineKeys = outline.map { (key: matchKey($0.title), entry: $0) }
        var pageForLabel: [String: Int] = [:]
        for (page, label) in printedPageNumbers.sorted(by: { $0.key < $1.key }) where pageForLabel[label] == nil {
            pageForLabel[label] = page
        }
        func pdfPage(forPrinted label: String) -> Int? {
            if let page = pageForLabel[label] { return page }
            // Chapter openers often print no page number; look next door.
            guard let n = Int(label) else { return nil }
            if let before = pageForLabel[String(n - 1)] { return before + 1 }
            if let after = pageForLabel[String(n + 1)] { return after - 1 }
            return nil
        }
        func contains(_ a: String, _ b: String) -> Bool {
            let (short, long) = a.count < b.count ? (a, b) : (b, a)
            return short.count >= 8 && long.contains(short)
        }

        for index in entries {
            guard case .paragraph(var runs, let indented) = blocks[index].block,
                  !runs.contains(where: { $0.link != nil }) else { continue }
            let key = matchKey(runs.joinedText)
            guard key.count >= 2 else { continue }
            var target: Link?
            if let hit = outlineKeys.first(where: { $0.key == key }) {
                target = .page(hit.entry.page, y: hit.entry.y)
            } else if let hit = headings.first(where: { $0.key == key }) {
                target = .page(blocks[hit.index].page, y: blocks[hit.index].y)
            } else if let label = blocks[index].contentsPageNumber, let page = pdfPage(forPrinted: label) {
                target = .page(page, y: nil)
            } else if let hit = outlineKeys.first(where: { contains($0.key, key) }) {
                target = .page(hit.entry.page, y: hit.entry.y)
            } else if let hit = headings.first(where: { contains($0.key, key) }) {
                target = .page(blocks[hit.index].page, y: blocks[hit.index].y)
            }
            guard let target else { continue }
            runs.modify(characters: 0..<runs.joinedText.count) { $0.link = target }
            blocks[index].block = .paragraph(runs, indented: indented)
        }
    }

    // MARK: - Links to places in the PDF

    /// Turns links to a PDF page (and spot on it) into links to the block of
    /// text found there, marking that block with an anchor.
    static func resolvePageLinks(_ blocks: [PositionedBlock], bodySize: Double) -> [PositionedBlock] {
        var targets = Set<Link>()
        for block in blocks {
            for run in block.block.runs ?? [] {
                if let link = run.link, case .page = link { targets.insert(link) }
            }
        }
        guard !targets.isEmpty else { return blocks }

        var byPage: [Int: [Int]] = [:]
        for (i, block) in blocks.enumerated() {
            switch block.block {
            case .anchor, .footnote: continue
            default: byPage[block.page, default: []].append(i)
            }
        }
        let pages = byPage.keys.sorted()
        func targetIndex(page: Int, y: Double?) -> Int? {
            if let onPage = byPage[page] {
                if let y, let hit = onPage.last(where: { blocks[$0].y <= y + bodySize }) { return hit }
                return onPage.first
            }
            // Nothing starts on that page (a picture, or text carried over): use what follows.
            return pages.first(where: { $0 > page }).flatMap { byPage[$0]?.first }
        }

        var anchorAt: [Int: String] = [:]
        var anchorFor: [Link: String] = [:]
        for target in targets {
            guard case .page(let page, let y) = target, let index = targetIndex(page: page, y: y) else { continue }
            let id = anchorAt[index] ?? "p\(blocks[index].page + 1)-\(index)"
            anchorAt[index] = id
            anchorFor[target] = id
        }

        var result: [PositionedBlock] = []
        result.reserveCapacity(blocks.count + anchorAt.count)
        for (i, block) in blocks.enumerated() {
            if let id = anchorAt[i] {
                result.append(PositionedBlock(block: .anchor(id), page: block.page, y: block.y))
            }
            var copy = block
            if let runs = block.block.runs {
                copy.block = block.block.withRuns(runs.map { run in
                    guard let link = run.link, case .page = link else { return run }
                    var run = run
                    run.link = anchorFor[link].map { .anchor($0) }
                    return run
                })
            }
            result.append(copy)
        }
        return result
    }

    // MARK: - Endnotes

    static let notesTitlePattern = try! NSRegularExpression(
        pattern: #"^\s*(end\s?notes|notes|notes and sources|source notes|notes to the text|notes on sources)\s*$"#,
        options: [.caseInsensitive])
    static let leadingNumberPattern = try! NSRegularExpression(pattern: #"^(\d{1,3})(?:[.)]\s*|\s+)"#)

    /// Whether an unnumbered paragraph is the rest of the note before it (a
    /// hanging indent) rather than something new, like a chapter name.
    static func continuesNote(_ note: [TextRun], with next: [TextRun]) -> Bool {
        let endsSentence = note.joinedText.last.map { terminalPunctuation.contains($0) } ?? false
        let startsLower = next.joinedText.first?.isLowercase ?? false
        return !endsSentence || startsLower
    }

    /// The note number a paragraph in a notes section starts with.
    static func leadingNumber(_ runs: [TextRun]) -> (number: Int, digits: Int)? {
        if let first = runs.first, first.superscript, let n = Int(first.text.trimmingCharacters(in: .whitespaces)) {
            return (n, first.text.count)
        }
        let text = runs.joinedText
        guard let match = leadingNumberPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let group = Range(match.range(at: 1), in: text), let n = Int(text[group]) else { return nil }
        return (n, text[group].count)
    }

    /// Links superscript numbers in the text to the numbered notes in a
    /// "Notes" section, and each note back to where it's cited. Notes are
    /// often numbered afresh for each chapter, grouped under the chapter's
    /// name; each group is matched to its chapter by name, or else in order.
    static func linkEndnotes(_ chapters: inout [Chapter]) {
        func isNotesTitle(_ text: String?) -> Bool { text.map { matches(notesTitlePattern, $0) } ?? false }
        guard let notesIndex = chapters.lastIndex(where: {
            isNotesTitle($0.title) || isNotesTitle(firstHeadingText($0.blocks))
        }) else { return }

        // Read the numbered notes. Lines that don't start with a number continue
        // the note before (hanging indents otherwise look like new paragraphs).
        var blocks: [Block] = []
        var notes: [(block: Int, number: Int, digits: Int, group: Int)] = []
        var groupHeadings: [Int: String] = [:]
        var lastHeading: String?
        var group = -1
        var lastNumber = Int.max
        for block in chapters[notesIndex].blocks {
            switch block {
            case .heading(_, let runs):
                lastHeading = runs.joinedText
                blocks.append(block)
            case .paragraph(let runs, let indented):
                if let (number, digits) = leadingNumber(runs) {
                    if number <= lastNumber || group < 0 {
                        group += 1
                        groupHeadings[group] = lastHeading
                    }
                    lastNumber = number
                    notes.append((blocks.count, number, digits, group))
                    blocks.append(block)
                } else if let last = notes.last, last.block == blocks.count - 1,
                          case .paragraph(var previous, let previousIndent) = blocks[last.block],
                          continuesNote(previous, with: runs) {
                    join(&previous, with: runs, hyphenatedWords: [])
                    blocks[last.block] = .paragraph(compact(previous), indented: previousIndent)
                } else {
                    // Short unnumbered lines between notes name the chapter they belong to.
                    if runs.joinedText.count <= 100 { lastHeading = runs.joinedText }
                    blocks.append(.paragraph(runs, indented: indented))
                }
            default:
                blocks.append(block)
            }
        }
        guard notes.count >= 2 else { return }

        // Superscript numbers in the chapters before the notes.
        var refs: [Int: [(block: Int, run: Int, number: Int)]] = [:]
        for c in 0..<notesIndex {
            for (b, block) in chapters[c].blocks.enumerated() {
                for (r, run) in (block.runs ?? []).enumerated() where run.superscript && run.link == nil {
                    if let n = Int(run.text.trimmingCharacters(in: .whitespaces)) {
                        refs[c, default: []].append((b, r, n))
                    }
                }
            }
        }
        let citing = refs.keys.sorted()
        guard !citing.isEmpty else { return }

        // Which chapter each group of notes belongs to.
        let groupCount = group + 1
        var chapterForGroup: [Int: Int] = [:]
        if groupCount == 1 {
            chapterForGroup[0] = -1   // numbered straight through the book
        } else {
            var next = 0
            for g in 0..<groupCount {
                let key = groupHeadings[g].map(matchKey) ?? ""
                let named = key.count >= 4 ? citing.first(where: { c in
                    let title = matchKey(chapters[c].title)
                    return title == key || (min(title.count, key.count) >= 6 && (title.contains(key) || key.contains(title)))
                }) : nil
                if let named {
                    chapterForGroup[g] = named
                    next = (citing.firstIndex(of: named) ?? next) + 1
                } else if next < citing.count {
                    chapterForGroup[g] = citing[next]
                    next += 1
                }
            }
        }

        var noteIDs: [Int: String] = [:]        // index in blocks -> id
        var citedNotes = Set<Int>()
        for (n, note) in notes.enumerated() {
            guard let chapter = chapterForGroup[note.group] else { continue }
            let chaptersToSearch = chapter < 0 ? citing : [chapter]
            let id = "en\(note.group + 1)-\(note.number)"
            let refID = "enref\(note.group + 1)-\(note.number)"
            var firstRef = true
            for c in chaptersToSearch {
                for ref in refs[c] ?? [] where ref.number == note.number {
                    var runs = chapters[c].blocks[ref.block].runs ?? []
                    guard ref.run < runs.count, runs[ref.run].link == nil else { continue }
                    runs[ref.run].link = .anchor(id)
                    if firstRef { runs[ref.run].id = refID }
                    chapters[c].blocks[ref.block] = chapters[c].blocks[ref.block].withRuns(runs)
                    if firstRef {
                        // Link the note's number back to where it's first cited.
                        var noteRuns = blocks[note.block].runs ?? []
                        let text = noteRuns.joinedText
                        let start = text.firstIndex(where: { $0.isNumber }).map { text.distance(from: text.startIndex, to: $0) } ?? 0
                        noteRuns.modify(characters: start..<(start + note.digits)) { $0.link = .anchor(refID) }
                        blocks[note.block] = blocks[note.block].withRuns(noteRuns)
                    }
                    firstRef = false
                }
            }
            noteIDs[note.block] = id
            if !firstRef { citedNotes.insert(n) }
        }
        guard !citedNotes.isEmpty else { return }

        var withAnchors: [Block] = []
        for (i, block) in blocks.enumerated() {
            if let id = noteIDs[i] { withAnchors.append(.anchor(id)) }
            withAnchors.append(block)
        }
        chapters[notesIndex].blocks = withAnchors
    }
}
