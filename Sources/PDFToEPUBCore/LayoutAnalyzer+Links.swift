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
                    guard let link = run.link, case .page(let target, _) = link else { return run }
                    var run = run
                    // A note marker points ahead to its note. One that points back
                    // (PDFs sometimes send these to the front of the book) is wrong.
                    run.link = run.superscript && target < block.page ? nil : anchorFor[link].map { .anchor($0) }
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

    /// Note reference numbers as read, in order, with misread ones corrected
    /// from the sequence: 1, 2, 3, 4, 5, *4*, 7 becomes 1, 2, 3, 4, 5, 6, 7. A
    /// number cited again (…, 5, 3, 6, …) is left alone. When the numbers are
    /// mostly out of sequence, their order alone is used.
    static func sequenced(_ read: [Int]) -> [Int] {
        guard !read.isEmpty else { return read }
        var fixed = read
        var previous = max(0, read[0] - 1)
        if read.count >= 2, read[0] != 1, read[1] == 2 { previous = 0 }
        for i in fixed.indices {
            let next = i + 1 < read.count ? read[i + 1] : nil
            if fixed[i] <= 0 {
                fixed[i] = previous + 1      // number unknown: next in the sequence
            } else if fixed[i] != previous + 1, next == previous + 2 {
                fixed[i] = previous + 1
            }
            // A number cited again doesn't move the sequence on.
            previous = max(previous, fixed[i])
        }
        // Numbers that neither continue the sequence nor repeat an earlier one.
        var seen = Set([fixed[0]]), highest = fixed[0], breaks = 0
        for number in fixed.dropFirst() {
            if number != highest + 1 && !seen.contains(number) { breaks += 1 }
            seen.insert(number)
            highest = max(highest, number)
        }
        if fixed.count >= 4, Double(breaks) > Double(fixed.count) * 0.3 {
            let start = max(1, read.min() ?? 1)
            return Array(start..<(start + fixed.count))
        }
        return fixed
    }

    /// How a note's number is set: "sup" (raised), "." ("12." or "12)") or " " ("12 Text").
    static func numberStyle(_ runs: [TextRun], digits: Int) -> String {
        if runs.first?.superscript == true { return "sup" }
        let text = runs.joinedText
        guard let digit = text.firstIndex(where: \.isNumber),
              let after = text.index(digit, offsetBy: digits, limitedBy: text.endIndex), after < text.endIndex
        else { return " " }
        return ".)".contains(text[after]) ? "." : " "
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

        // Read the numbered notes. A note runs until the next note in the
        // numbering: its later paragraphs, and lines that happen to start with
        // a number ("12 (3): 45–67."), are part of it, so the whole note shows
        // when Books pops it up. Numbering starting again at 1 begins the notes
        // for the next chapter, and a short line just before names it.
        func noteText(_ block: Block) -> [TextRun]? {
            switch block {
            case .paragraph(let runs, _), .quote(let runs): return runs
            default: return nil
            }
        }
        // The notes may be split into a chapter for each chapter they belong
        // to ("Notes to Chapter 2"); those follow on while they're mostly notes.
        var notesEnd = notesIndex + 1
        while notesEnd < chapters.count {
            let texts = chapters[notesEnd].blocks.compactMap(noteText)
            let numbered = texts.filter { leadingNumber($0) != nil }.count
            guard numbered >= 2, Double(numbered) >= Double(texts.count) * 0.4 else { break }
            notesEnd += 1
        }
        let notesChapters = notesIndex..<notesEnd
        var source: [Block] = []
        var sourceOwner: [Int] = []
        for c in notesChapters {
            source += chapters[c].blocks
            sourceOwner += Array(repeating: c, count: chapters[c].blocks.count)
        }
        func nextNumber(after index: Int) -> Int? {
            for block in source[(index + 1)...] {
                if case .heading = block { return nil }
                if let runs = noteText(block), let (number, _) = leadingNumber(runs) { return number }
            }
            return nil
        }
        var blocks: [Block] = []
        var owners: [Int] = []             // the chapter each block goes back into
        var notes: [(block: Int, number: Int, digits: Int, group: Int)] = []
        var groupHeadings: [Int: String] = [:]
        var lastHeading: String?
        var group = -1
        var lastNumber = 0
        var styles: [String: Int] = [:]      // how notes start: "12.", "12 ", or a raised 12
        for (index, block) in source.enumerated() {
            let owner = sourceOwner[index]
            if index > 0, owner != sourceOwner[index - 1] { lastHeading = chapters[owner].title }
            if case .heading(_, let runs) = block {
                lastHeading = runs.joinedText
                blocks.append(block)
                owners.append(owner)
                continue
            }
            guard let runs = noteText(block) else {
                blocks.append(block)
                owners.append(owner)
                continue
            }
            let text = runs.joinedText.trimmingCharacters(in: .whitespaces)
            let numbered = leadingNumber(runs)
            let inNote = notes.last.map { $0.block == blocks.count - 1 && owners[$0.block] == owner } ?? false
            if let (number, digits) = numbered {
                let style = numberStyle(runs, digits: digits)
                let usual = notes.count >= 3 ? styles.max { $0.value < $1.value }?.key : nil
                let restart = number <= 2 && number < lastNumber
                let next = number > lastNumber && number <= lastNumber + 3
                if notes.isEmpty || !inNote || ((next || restart) && (usual == nil || style == usual)) {
                    if group < 0 || restart || (!inNote && number < lastNumber) {
                        group += 1
                        groupHeadings[group] = lastHeading
                    }
                    lastNumber = number
                    styles[style, default: 0] += 1
                    notes.append((blocks.count, number, digits, group))
                    blocks.append(.paragraph(runs, indented: false))
                    owners.append(owner)
                    continue
                }
            }
            if inNote, let last = notes.last {
                let endsSentence = text.last.map { terminalPunctuation.contains($0) } ?? false
                let namesNextGroup = numbered == nil && text.count <= 100 && !endsSentence
                    && (nextNumber(after: index) ?? Int.max) <= 2
                if !namesNextGroup, case .paragraph(var previous, _) = blocks[last.block] {
                    if continuesNote(previous, with: runs) {
                        join(&previous, with: runs, hyphenatedWords: [])
                    } else {
                        previous.append(TextRun(text: "\n"))
                        previous.append(contentsOf: runs)
                    }
                    blocks[last.block] = .paragraph(compact(previous), indented: false)
                    continue
                }
            }
            // Short unnumbered lines between notes name the chapter they belong to.
            if text.count <= 100 { lastHeading = text }
            blocks.append(block)
            owners.append(owner)
        }
        guard notes.count >= 2 else { return }

        // Superscript numbers in the chapters before the notes. Matching them
        // here beats a link from the PDF that doesn't lead into the notes.
        var notesIDs = Set<String>()
        for c in notesChapters {
            for block in chapters[c].blocks {
                if case .anchor(let id) = block { notesIDs.insert(id) }
            }
        }
        func replaceable(_ link: Link?) -> Bool {
            guard let link else { return true }
            if case .anchor(let id) = link { return !id.hasPrefix("fn") && !notesIDs.contains(id) }
            return false
        }
        // Where the PDF's own links from note markers land among the notes.
        // They often lead only to the page a note is on (so to the first note
        // there), which says whose notes to look in but not which note.
        var anchorPosition: [String: Int] = [:]
        for (i, block) in blocks.enumerated() {
            if case .anchor(let id) = block { anchorPosition[id] = i }
        }
        var refs: [Int: [(block: Int, run: Int, number: Int, hint: Int?)]] = [:]
        for c in 0..<notesIndex {
            for (b, block) in chapters[c].blocks.enumerated() {
                for (r, run) in (block.runs ?? []).enumerated() where run.superscript {
                    var hint: Int?
                    if case .anchor(let id)? = run.link { hint = anchorPosition[id] }
                    guard hint != nil || replaceable(run.link) else { continue }
                    // "*": a marker recovered from the drawing, its number unknown (0).
                    let text = run.text.trimmingCharacters(in: .whitespaces)
                    if let n = Int(text) ?? (text == "*" ? 0 : nil) {
                        refs[c, default: []].append((b, r, n, hint))
                    }
                }
            }
        }
        let citing = refs.keys.sorted()
        guard !citing.isEmpty else { return }

        // Which chapter each group of notes belongs to. Groups and chapters are
        // lined up in order, favouring pairs whose numbers agree (a chapter
        // citing notes 1–24 for a group of 24 notes) and whose names match, and
        // skipping chapters whose note references weren't found.
        let groupCount = group + 1

        // A note number's digits can be misread (InDesign's superscript
        // figures sometimes carry the wrong character codes: a printed 6 read
        // as 4). Markers come in order, so one that breaks the sequence
        // takes its place in it.
        if groupCount == 1 {
            let fixed = sequenced(citing.flatMap { (refs[$0] ?? []).map(\.number) })
            var k = 0
            for c in citing {
                for i in (refs[c] ?? []).indices {
                    refs[c]![i].number = fixed[k]
                    k += 1
                }
            }
        } else {
            for c in citing {
                let fixed = sequenced((refs[c] ?? []).map(\.number))
                for i in fixed.indices { refs[c]![i].number = fixed[i] }
            }
        }

        // Each marker the PDF links into the notes votes for the group holding
        // the note with its number nearest after where the link lands.
        var votes: [Int: [Int: Int]] = [:]      // chapter -> group -> votes
        for c in citing {
            for ref in refs[c] ?? [] {
                guard let hint = ref.hint else { continue }
                guard let landing = notes.first(where: { $0.block >= hint - 1 }) ?? notes.last else { continue }
                let near = notes.filter { $0.number == ref.number && abs($0.group - landing.group) <= 1 }
                let note = near.min { abs($0.block - hint) < abs($1.block - hint) } ?? landing
                votes[c, default: [:]][note.group, default: 0] += 1
            }
        }

        var chapterForGroup: [Int: Int] = [:]
        if groupCount == 1 {
            chapterForGroup[0] = -1   // numbered straight through the book
        } else {
            var groupNumbers = Array(repeating: Set<Int>(), count: groupCount)
            for note in notes { groupNumbers[note.group].insert(note.number) }
            let refNumbers = citing.map { Set((refs[$0] ?? []).map(\.number)) }
            func similarity(_ g: Int, _ k: Int) -> Double {
                let union = groupNumbers[g].union(refNumbers[k]).count
                var score = union == 0 ? 0 : Double(groupNumbers[g].intersection(refNumbers[k]).count) / Double(union)
                let key = groupHeadings[g].map(matchKey) ?? ""
                let title = matchKey(chapters[citing[k]].title)
                if key.count >= 4, title == key || (min(title.count, key.count) >= 6 && (title.contains(key) || key.contains(title))) {
                    score += 1
                }
                // The PDF's links outweigh everything else.
                let chapterVotes = votes[citing[k]] ?? [:]
                let total = chapterVotes.values.reduce(0, +)
                if total > 0 { score += 3 * Double(chapterVotes[g] ?? 0) / Double(total) }
                return score
            }
            let k = citing.count
            var best = Array(repeating: Array(repeating: 0.0, count: k + 1), count: groupCount + 1)
            for g in 1...groupCount {
                for c in 1...max(1, k) where k > 0 {
                    let pair = similarity(g - 1, c - 1)
                    best[g][c] = max(best[g - 1][c], best[g][c - 1], pair > 0 ? best[g - 1][c - 1] + pair : 0)
                }
            }
            var g = groupCount, c = k
            while g > 0 && c > 0 {
                let pair = similarity(g - 1, c - 1)
                if pair > 0 && best[g][c] == best[g - 1][c - 1] + pair {
                    chapterForGroup[g - 1] = citing[c - 1]
                    g -= 1
                    c -= 1
                } else if best[g][c] == best[g - 1][c] {
                    g -= 1
                } else {
                    c -= 1
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
                    guard ref.run < runs.count, ref.hint != nil || replaceable(runs[ref.run].link) else { continue }
                    runs[ref.run].link = .anchor(id)
                    runs[ref.run].text = "\(note.number)"   // as corrected, or recovered
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

        for c in notesChapters { chapters[c].blocks = [] }
        for (i, block) in blocks.enumerated() {
            if let id = noteIDs[i] { chapters[owners[i]].blocks.append(.anchor(id)) }
            chapters[owners[i]].blocks.append(block)
        }
    }
}
