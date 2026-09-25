#if canImport(PDFKit)
import Foundation
import PDFKit

public struct ConversionOptions {
    /// Leave nil to use what the PDF says (or the file name).
    public var title: String?
    public var author: String?
    /// Use a picture of the first page as the book cover.
    public var includeCover = true
    public var extraction = ExtractionOptions()
    public var layout = LayoutOptions()

    public init() {}
}

public struct ConversionResult {
    public var outputURL: URL
    public var pageCount: Int
    public var chapterTitles: [String]
    public var recognizedPageCount: Int
    public var imagePageCount: Int
    public var wordCount: Int
    public var usedOutline: Bool
}

public enum ConversionError: LocalizedError {
    case cannotOpen(URL)
    case locked
    case noContent

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): return "“\(url.lastPathComponent)” couldn’t be opened as a PDF."
        case .locked: return "This PDF is password protected. Unlock it in Preview first, then try again."
        case .noContent: return "No readable text or pages were found in this PDF."
        }
    }
}

public enum PDFToEPUBConverter {
    public struct Details {
        public var title: String
        public var author: String
        public var pageCount: Int
    }

    /// Title, author and page count to prefill the form with.
    public static func details(for url: URL) -> Details? {
        guard let document = PDFDocument(url: url) else { return nil }
        let attributes = document.documentAttributes ?? [:]
        let title = cleanTitle(attributes[PDFDocumentAttribute.titleAttribute] as? String, url: url)
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Details(title: title, author: author, pageCount: document.pageCount)
    }

    public static func convert(input: URL, output: URL, options: ConversionOptions = ConversionOptions(),
                               progress: @escaping (Double, String) -> Void = { _, _ in }) throws -> ConversionResult {
        guard let document = PDFDocument(url: input) else { throw ConversionError.cannotOpen(input) }
        if document.isLocked && !document.unlock(withPassword: "") { throw ConversionError.locked }

        progress(0, "Reading pages…")
        let extractor = PDFExtractor(document: document)
        let extracted = try extractor.extract(options: options.extraction) { done, total in
            progress(0.85 * Double(done) / Double(max(total, 1)), "Reading page \(min(done + 1, total)) of \(total)…")
        }

        var layout = options.layout
        var cover: BookImage?
        if options.includeCover, let first = document.page(at: 0) {
            cover = extractor.pageImage(first, maxDimension: 1800)
            // If the first page is mostly a picture (a real cover), don't repeat it in the text.
            let firstPageText = extracted.lines.filter { $0.page == 0 }.reduce(0) { $0 + $1.text.count }
            if firstPageText < 200 || extracted.pageImages.contains(where: { $0.page == 0 }) {
                layout.skipPages.insert(0)
            }
        }

        let title = nonEmpty(options.title) ?? cleanTitle(extracted.title, url: input)
        layout.fallbackTitle = title

        progress(0.88, "Finding chapters and paragraphs…")
        try Task.checkCancellation()
        let chapters = LayoutAnalyzer(options: layout)
            .analyze(lines: extracted.lines, pageImages: extracted.pageImages, outline: extracted.outline)
        guard !chapters.isEmpty else { throw ConversionError.noContent }

        let metadata = BookMetadata(title: title,
                                    author: nonEmpty(options.author) ?? extracted.author ?? "",
                                    language: extracted.language ?? "en",
                                    subject: extracted.subject)
        let book = Book(metadata: metadata, cover: cover, chapters: chapters)

        progress(0.95, "Writing EPUB…")
        try EPUBWriter().write(book, to: output)
        progress(1, "Done")

        let words = chapters.flatMap(\.blocks).reduce(0) { total, block in
            switch block {
            case .paragraph(let runs, _), .heading(_, let runs):
                return total + runs.map(\.text).joined().split(whereSeparator: \.isWhitespace).count
            default:
                return total
            }
        }
        let usedOutline = layout.useOutline && extracted.outline.count >= 2
        return ConversionResult(outputURL: output, pageCount: extracted.pageCount,
                                chapterTitles: chapters.map(\.title),
                                recognizedPageCount: extracted.recognizedPages.count,
                                imagePageCount: extracted.pageImages.filter { !layout.skipPages.contains($0.page) }.count,
                                wordCount: words, usedOutline: usedOutline)
    }

    /// PDF titles are often left over from whatever made the file
    /// ("Microsoft Word - draft3.docx"). Fall back to the file name then.
    static func cleanTitle(_ title: String?, url: URL) -> String {
        let fileTitle = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
        guard let title = nonEmpty(title) else { return fileTitle }
        let lowered = title.lowercased()
        let junk = ["microsoft word", ".doc", ".pdf", ".indd", "untitled", ".tex", ".qxd"]
        if junk.contains(where: lowered.contains) || title.count < 2 { return fileTitle }
        return title
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
#endif
