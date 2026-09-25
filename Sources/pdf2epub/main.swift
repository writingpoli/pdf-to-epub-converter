import Foundation
import PDFToEPUBCore
#if canImport(AppKit)
import AppKit
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

/// Input format for --lines-json.
struct LinesDump: Decodable {
    var lines: [TextLine]
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

let isTerminal = isatty(fileno(stderr)) != 0
do {
    var lastReported = -1
    let result = try PDFToEPUBConverter.convert(input: inputURL, output: outputURL, options: options) { fraction, message in
        let percent = Int(fraction * 100)
        guard percent != lastReported else { return }
        lastReported = percent
        if isTerminal {
            FileHandle.standardError.write(Data("\r\u{1B}[K\(percent)%  \(message)".utf8))
        }
    }
    if isTerminal { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
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
