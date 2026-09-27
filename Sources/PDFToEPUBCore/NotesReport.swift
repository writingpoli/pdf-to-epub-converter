import Foundation

/// A summary of how a converted book's note references and endnotes were
/// linked, for diagnosing pop-ups that show the wrong note or none. Text is
/// passed through `mask` so the report holds no words from the book.
public enum NotesReport {
    public static func summary(_ chapters: [Chapter], mask: (String) -> String) -> String {
        var out = ""
        // Where each note anchor is, and the note text that follows it.
        var noteText: [String: String] = [:]
        var noteChapter: [String: Int] = [:]
        for (c, chapter) in chapters.enumerated() {
            var pending: String?
            for block in chapter.blocks {
                if case .anchor(let id) = block { pending = id; continue }
                if let id = pending, let runs = block.runs { noteText[id] = runs.joinedText; noteChapter[id] = c }
                if case .footnote(let id, let runs) = block { noteText[id] = runs.joinedText; noteChapter[id] = c }
                pending = nil
            }
        }

        var linkedEnd = 0, linkedFoot = 0, linkedOther = 0, unlinked = 0
        var citedGroups: [String: [Int: Int]] = [:]    // group -> chapter -> markers
        for (c, chapter) in chapters.enumerated() {
            for block in chapter.blocks {
                for run in block.runs ?? [] where run.superscript {
                    guard let link = run.link else { unlinked += 1; continue }
                    if case .anchor(let id) = link, id.hasPrefix("en") {
                        linkedEnd += 1
                        let group = String(id.dropFirst(2).prefix { $0 != "-" })
                        citedGroups[group, default: [:]][c, default: 0] += 1
                    } else if case .anchor(let id) = link, id.hasPrefix("fn") {
                        linkedFoot += 1
                    } else {
                        linkedOther += 1
                    }
                }
            }
        }
        out += "Note markers in the text: \(linkedEnd) linked to endnotes, \(linkedFoot) to footnotes, "
        out += "\(linkedOther) to something else, \(unlinked) not linked\n"

        let endnotes = noteText.keys.filter { $0.hasPrefix("en") && !$0.hasPrefix("enref") }
        let byGroup = Dictionary(grouping: endnotes) { String($0.dropFirst(2).prefix { $0 != "-" }) }
        let notesChapters = Set(endnotes.compactMap { noteChapter[$0] }).sorted()
        out += "Endnotes found: \(endnotes.count), in \(byGroup.count) groups, in chapters "
        out += notesChapters.map { "\"\(mask(chapters[$0].title))\"" }.joined(separator: ", ") + "\n"
        for group in byGroup.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
            let ids = byGroup[group] ?? []
            let numbers = ids.compactMap { Int($0.split(separator: "-").last ?? "") }.sorted()
            let lengths = ids.map { noteText[$0]?.count ?? 0 }
            let cited = (citedGroups[group] ?? [:]).sorted { $0.key < $1.key }
                .map { "\"\(mask(chapters[$0.key].title))\" (\($0.value) markers)" }
            out += "  group \(group): notes \(numbers.first ?? 0)–\(numbers.last ?? 0) (\(ids.count)), "
            out += "average \(lengths.isEmpty ? 0 : lengths.reduce(0, +) / lengths.count) characters; "
            out += "cited from \(cited.isEmpty ? "nowhere" : cited.joined(separator: ", "))\n"
        }
        return out
    }

    /// Where a note marker found after `context` (the text just before it)
    /// links to, and the start of that note.
    public static func trace(marker: String, after context: String, in chapters: [Chapter],
                             mask: (String) -> String) -> String {
        let key = context.filter { $0.isLetter || $0.isNumber }.suffix(24)
        var noteText: [String: String] = [:]
        for chapter in chapters {
            var pending: String?
            for block in chapter.blocks {
                if case .anchor(let id) = block { pending = id; continue }
                if let id = pending, let runs = block.runs { noteText[id] = runs.joinedText }
                if case .footnote(let id, let runs) = block { noteText[id] = runs.joinedText }
                pending = nil
            }
        }
        for chapter in chapters {
            for block in chapter.blocks {
                var before = ""
                for run in block.runs ?? [] {
                    if run.superscript, !key.isEmpty, before.filter({ $0.isLetter || $0.isNumber }).hasSuffix(key) {
                        guard case .anchor(let id)? = run.link else { return "shown as ^\(run.text)^, not linked" }
                        let note = noteText[id] ?? ""
                        return "shown as ^\(run.text)^, links to \(id): \"\(mask(String(note.prefix(60))))…\" (\(note.count) characters)"
                    }
                    before += run.text
                }
            }
        }
        return "not found in the converted text"
    }
}
