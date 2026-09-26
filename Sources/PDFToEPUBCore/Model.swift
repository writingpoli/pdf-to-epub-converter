import Foundation

/// Where a link goes.
public enum Link: Codable, Equatable, Hashable {
    /// A spot in the PDF (a page, and optionally the distance from its top).
    /// The layout analyzer turns these into `anchor` links.
    case page(Int, y: Double?)
    /// An element in the book with this id.
    case anchor(String)
    /// A web or mail link.
    case url(String)
}

/// A styled piece of text within a line or paragraph.
public struct TextRun: Codable, Equatable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    /// Raised small text, usually a note reference.
    public var superscript: Bool
    public var link: Link?
    /// An id other links can point at (for example a note reference, so the
    /// note can link back to it).
    public var id: String?

    public init(text: String, bold: Bool = false, italic: Bool = false, superscript: Bool = false,
                link: Link? = nil, id: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.superscript = superscript
        self.link = link
        self.id = id
    }

    enum CodingKeys: String, CodingKey { case text, bold, italic, superscript, link, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        superscript = try c.decodeIfPresent(Bool.self, forKey: .superscript) ?? false
        link = try c.decodeIfPresent(Link.self, forKey: .link)
        id = try c.decodeIfPresent(String.self, forKey: .id)
    }

    /// Same styling and link, so the two can be merged into one run.
    func hasSameStyle(as other: TextRun) -> Bool {
        bold == other.bold && italic == other.italic && superscript == other.superscript
            && link == other.link && id == nil && other.id == nil
    }
}

extension Array where Element == TextRun {
    /// Inserts a run at a character offset of the joined text, splitting the run there.
    mutating func insert(_ run: TextRun, atCharacter offset: Int) {
        var position = 0
        for i in indices {
            let count = self[i].text.count
            if offset <= position + count {
                let cut = offset - position
                if cut == 0 { insert(run, at: i); return }
                if cut == count { insert(run, at: i + 1); return }
                var head = self[i], tail = self[i]
                head.text = String(self[i].text.prefix(cut))
                tail.text = String(self[i].text.dropFirst(cut))
                tail.id = nil
                replaceSubrange(i...i, with: [head, run, tail])
                return
            }
            position += count
        }
        append(run)
    }

    /// Splits runs so that `range` (in characters of the joined text) is
    /// covered by whole runs, then lets `change` edit those runs.
    mutating func modify(characters range: Range<Int>, _ change: (inout TextRun) -> Void) {
        var result: [TextRun] = []
        var offset = 0
        for run in self {
            let count = run.text.count
            let start = offset, end = offset + count
            offset = end
            let lo = Swift.max(start, range.lowerBound), hi = Swift.min(end, range.upperBound)
            guard lo < hi else {
                result.append(run)
                continue
            }
            let chars = [Character](run.text)
            if lo > start {
                var before = run
                before.text = String(chars[0..<(lo - start)])
                before.id = nil
                result.append(before)
            }
            var middle = run
            middle.text = String(chars[(lo - start)..<(hi - start)])
            change(&middle)
            result.append(middle)
            if hi < end {
                var after = run
                after.text = String(chars[(hi - start)...])
                after.id = nil
                result.append(after)
            }
        }
        self = result
    }

    var joinedText: String { map(\.text).joined() }

    /// Marks note numbers that a PDF reader handed back as a run of their own,
    /// stuck to the word or punctuation before them ("again.1", "off).12").
    /// Raised numbers often keep the text's font size, so this is sometimes
    /// the only sign of them.
    public mutating func markAttachedNoteMarkers() {
        for i in indices.dropFirst() where !self[i].superscript {
            let text = self[i].text
            guard text.count <= 3, text.allSatisfy({ $0.isNumber }) || text.allSatisfy({ "*†‡§¶".contains($0) }),
                  let before = self[i - 1].text.last,
                  before.isLetter || ".,;:!?)”’\"'".contains(before) else { continue }
            if i + 1 < count, let after = self[i + 1].text.first, after.isLetter || after.isNumber { continue }
            self[i].superscript = true
        }
    }
}

/// One line of text as it appears on a PDF page.
///
/// Coordinates are in PDF points with the origin at the *top-left* of the page,
/// so `y` grows downward the way you read.
public struct TextLine: Codable, Equatable {
    public var runs: [TextRun]
    public var page: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var fontSize: Double
    public var pageWidth: Double
    public var pageHeight: Double
    /// The typeface family most of the line is set in, when known.
    public var fontName: String?

    public init(runs: [TextRun], page: Int, x: Double, y: Double, width: Double, height: Double,
                fontSize: Double, pageWidth: Double, pageHeight: Double, fontName: String? = nil) {
        self.fontName = fontName
        self.runs = runs
        self.page = page
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.fontSize = fontSize
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
    }

    public var text: String { runs.map(\.text).joined() }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isItalic: Bool {
        let letters = runs.filter { $0.text.contains(where: \.isLetter) }
        return !letters.isEmpty && letters.allSatisfy(\.italic)
    }
    /// Set in capitals, like "THE LONG WAY HOME".
    public var isAllCaps: Bool {
        let letters = text.filter(\.isLetter)
        return letters.count >= 3 && letters.allSatisfy(\.isUppercase)
    }
    public var isBold: Bool {
        let letters = runs.filter { $0.text.contains(where: \.isLetter) }
        return !letters.isEmpty && letters.allSatisfy(\.bold)
    }
}

/// An image that ends up in the EPUB (a cover, or a page kept as a picture).
public struct BookImage: Equatable {
    public var data: Data
    public var mediaType: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(data: Data, mediaType: String, pixelWidth: Int, pixelHeight: Int) {
        self.data = data
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var fileExtension: String { mediaType == "image/png" ? "png" : "jpg" }
}

/// Content that isn't text lines: a page that should be shown as a picture.
public struct PageImage: Equatable {
    public var page: Int
    public var image: BookImage
    public var altText: String

    public init(page: Int, image: BookImage, altText: String) {
        self.page = page
        self.image = image
        self.altText = altText
    }
}

/// A bookmark from the PDF's outline (its built-in table of contents).
public struct OutlineEntry: Codable, Equatable {
    public var title: String
    public var page: Int
    /// Distance from the top of the page, if the bookmark points at a spot on the page.
    public var y: Double?
    public var level: Int

    public init(title: String, page: Int, y: Double? = nil, level: Int = 0) {
        self.title = title
        self.page = page
        self.y = y
        self.level = level
    }
}

public enum Block: Equatable {
    case heading(level: Int, runs: [TextRun])
    case paragraph([TextRun], indented: Bool)
    /// A block quotation: text set in from the margins.
    case quote([TextRun])
    case sceneBreak
    case image(BookImage, alt: String)
    /// Gives the block that follows an id links can point at.
    case anchor(String)
    /// A footnote, shown by Books as a pop-up from its reference.
    case footnote(id: String, runs: [TextRun])

    var runs: [TextRun]? {
        switch self {
        case .heading(_, let runs), .paragraph(let runs, _), .quote(let runs), .footnote(_, let runs): return runs
        default: return nil
        }
    }

    func withRuns(_ runs: [TextRun]) -> Block {
        switch self {
        case .heading(let level, _): return .heading(level: level, runs: runs)
        case .paragraph(_, let indented): return .paragraph(runs, indented: indented)
        case .quote: return .quote(runs)
        case .footnote(let id, _): return .footnote(id: id, runs: runs)
        default: return self
        }
    }
}

public struct Chapter: Equatable {
    public var title: String
    public var blocks: [Block]

    public init(title: String, blocks: [Block]) {
        self.title = title
        self.blocks = blocks
    }
}

public struct BookMetadata: Equatable {
    public var title: String
    public var author: String
    public var language: String
    public var identifier: String
    public var publisher: String?
    public var subject: String?

    public init(title: String, author: String = "", language: String = "en",
                identifier: String = "urn:uuid:" + UUID().uuidString.lowercased(),
                publisher: String? = nil, subject: String? = nil) {
        self.title = title
        self.author = author
        self.language = language
        self.identifier = identifier
        self.publisher = publisher
        self.subject = subject
    }
}

public struct Book: Equatable {
    public var metadata: BookMetadata
    public var cover: BookImage?
    public var chapters: [Chapter]

    public init(metadata: BookMetadata, cover: BookImage? = nil, chapters: [Chapter]) {
        self.metadata = metadata
        self.cover = cover
        self.chapters = chapters
    }
}

extension TextLine {
    /// Links the words of this line that read `linked`, ignoring differences
    /// in spacing. Returns false when they aren't on this line.
    @discardableResult
    public mutating func addLink(_ link: Link, text linked: String) -> Bool {
        let chars = Array(text)
        let hay = chars.indices.filter { !chars[$0].isWhitespace }
        let needle = linked.filter { !$0.isWhitespace }.map { $0 }
        guard !needle.isEmpty, needle.count <= hay.count else { return false }
        var found: Int?
        search: for start in 0...(hay.count - needle.count) {
            for k in 0..<needle.count where chars[hay[start + k]] != needle[k] { continue search }
            found = start
            break
        }
        guard let start = found else { return false }
        let range = hay[start]..<(hay[start + needle.count - 1] + 1)
        runs.modify(characters: range) { run in
            if run.link == nil { run.link = link }
        }
        return true
    }
}
