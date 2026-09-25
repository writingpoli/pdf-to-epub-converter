import Foundation

/// A styled piece of text within a line or paragraph.
public struct TextRun: Codable, Equatable {
    public var text: String
    public var bold: Bool
    public var italic: Bool

    public init(text: String, bold: Bool = false, italic: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
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

    public init(runs: [TextRun], page: Int, x: Double, y: Double, width: Double, height: Double,
                fontSize: Double, pageWidth: Double, pageHeight: Double) {
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
    case sceneBreak
    case image(BookImage, alt: String)
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
