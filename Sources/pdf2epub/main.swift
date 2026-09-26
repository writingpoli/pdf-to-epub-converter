import Foundation
import PDFToEPUBCore
#if canImport(AppKit)
import AppKit
import PDFKit
#endif

let usage = """
usage: pdf2epub <input.pdf> [options]

  -o, --output <file>   where to write the EPUB (default: next to the PDF)
  --title <text>        book title
  --author <text>       author name
  --no-cover            don't make a cover from the first page
  --no-ocr              don't run text recognition on scanned pages
  --keep-headers        keep running heads and page numbers
  --ignore-bookmarks    find chapters from headings even if the PDF has bookmarks
  --open                open the result in Apple Books when done
  --verbose             print every step with the time it started
  --diagnose <page>     print a report on one page's fonts and layout (text
                        masked) instead of converting
  --dump-lines <file>   save the text lines read from the PDF as JSON (for
                        diagnosing layout problems) instead of converting

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pdf2epub: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var input: String?
var output: String?
var title: String?
var author: String?
var includeCover = true
var ocr = true
var keepHeaders = false
var ignoreBookmarks = false
var openInBooks = false
var verbose = false
var dumpLines: String?
var diagnosePage: Int?
var linesJSON: String?   // debugging aid: run layout on lines dumped by another tool

while !arguments.isEmpty {
    let arg = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { fail("\(arg) needs a value") }
        return arguments.removeFirst()
    }
    switch arg {
    case "-o", "--output": output = value()
    case "--title": title = value()
    case "--author": author = value()
    case "--no-cover": includeCover = false
    case "--no-ocr": ocr = false
    case "--keep-headers": keepHeaders = true
    case "--ignore-bookmarks": ignoreBookmarks = true
    case "--open": openInBooks = true
    case "--verbose": verbose = true
    case "--dump-lines": dumpLines = value()
    case "--diagnose":
        let text = value()
        guard let page = Int(text) else { fail("--diagnose needs a page number, not \(text)") }
        diagnosePage = page
    case "--lines-json": linesJSON = value()
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)\n\n\(usage)") }
        input = arg
    }
}

var layout = LayoutOptions()
layout.removeHeadersAndFooters = !keepHeaders
layout.useOutline = !ignoreBookmarks

/// Format of --dump-lines output and --lines-json input.
struct LinesDump: Codable {
    var lines: [TextLine]
    /// The fonts in the PDF and whether each was read as bold or italic.
    var fonts: [FontReport]?
    var outline: [OutlineEntry]?
    var title: String?
    var author: String?
}

if let linesJSON {
    do {
        let dump = try JSONDecoder().decode(LinesDump.self, from: Data(contentsOf: URL(fileURLWithPath: linesJSON)))
        let bookTitle = title ?? dump.title ?? "Untitled"
        layout.fallbackTitle = bookTitle
        let chapters = LayoutAnalyzer(options: layout).analyze(lines: dump.lines, outline: dump.outline ?? [])
        let book = Book(metadata: BookMetadata(title: bookTitle, author: author ?? dump.author ?? ""), chapters: chapters)
        let out = URL(fileURLWithPath: output ?? (linesJSON as NSString).deletingPathExtension + ".epub")
        try EPUBWriter().write(book, to: out)
        print("Wrote \(out.path)")
        for chapter in chapters { print("  • \(chapter.title) (\(chapter.blocks.count) blocks)") }
    } catch {
        fail("\(error)")
    }
    exit(0)
}

#if canImport(PDFKit)
guard let input else {
    print(usage)
    exit(1)
}
let inputURL = URL(fileURLWithPath: input)
let outputURL = output.map { URL(fileURLWithPath: $0) }
    ?? inputURL.deletingPathExtension().appendingPathExtension("epub")

var options = ConversionOptions()
options.title = title
options.author = author
options.includeCover = includeCover
options.extraction.recognizeScannedPages = ocr
options.layout = layout

if let diagnosePage {
    print(Diagnostics.report(for: inputURL, page: diagnosePage))
    exit(0)
}

if let dumpLines {
    do {
        guard let document = PDFDocument(url: inputURL) else { fail("couldn't open \(input)") }
        let extractor = PDFExtractor(document: document)
        let extracted = try extractor.extract(options: options.extraction)
        let fonts = extractor.fonts.values.sorted { $0.characters > $1.characters }
        let dump = LinesDump(lines: extracted.lines, fonts: fonts, outline: extracted.outline,
                             title: extracted.title, author: extracted.author)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(dump).write(to: URL(fileURLWithPath: dumpLines))
        print("Wrote \(extracted.lines.count) lines from \(extracted.pageCount) pages to \(dumpLines)")
        print("Fonts (characters, style read):")
        for font in fonts {
            let style = [font.bold ? "bold" : nil, font.italic ? "italic" : nil].compactMap { $0 }
            print("  \(font.name)  \(font.characters)  \(style.isEmpty ? "regular" : style.joined(separator: " "))")
        }
    } catch {
        fail(error.localizedDescription)
    }
    exit(0)
}

let isTerminal = isatty(fileno(stderr)) != 0
do {
    var lastReported = -1
    var lastMessage = ""
    let started = Date()
    let result = try PDFToEPUBConverter.convert(input: inputURL, output: outputURL, options: options) { fraction, message in
        if verbose {
            guard message != lastMessage else { return }
            lastMessage = message
            let elapsed = String(format: "%7.2fs", Date().timeIntervalSince(started))
            FileHandle.standardError.write(Data("\(elapsed)  \(message)\n".utf8))
            return
        }
        let percent = Int(fraction * 100)
        guard percent != lastReported else { return }
        lastReported = percent
        if isTerminal {
            FileHandle.standardError.write(Data("\r\u{1B}[K\(percent)%  \(message)".utf8))
        }
    }
    if isTerminal && !verbose { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
    print("Wrote \(result.outputURL.path)")
    print("  \(result.pageCount) pages → \(result.chapterTitles.count) chapters, about \(result.wordCount) words")
    if result.recognizedPageCount > 0 { print("  \(result.recognizedPageCount) scanned pages read with text recognition") }
    if result.imagePageCount > 0 { print("  \(result.imagePageCount) pages kept as images") }
    print("  Chapters found from \(result.usedOutline ? "the PDF’s bookmarks" : "headings in the text"):")
    for chapterTitle in result.chapterTitles { print("    • \(chapterTitle)") }
    if openInBooks {
        let books = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iBooksX")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = books == nil ? [outputURL.path] : ["-b", "com.apple.iBooksX", outputURL.path]
        try process.run()
        process.waitUntilExit()
    }
} catch {
    fail(error.localizedDescription)
}
#else
fail("converting PDFs needs macOS (PDFKit). On other systems only --lines-json is available.")
#endif
