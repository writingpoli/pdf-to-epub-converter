#if canImport(PDFKit)
import AppKit
import Foundation
import PDFKit

/// A short, pasteable report on how a PDF reads: its fonts as macOS reports
/// them, the lines of one page with their positions and fonts, and what the
/// converter makes of that page. Letters are masked ("Xxxxx xxx"), so the
/// report shows the layout without the book's text.
public enum Diagnostics {
    public static func report(for url: URL, page pageNumber: Int) -> String {
        guard let document = PDFDocument(url: url) else { return "Couldn't open \(url.lastPathComponent) as a PDF." }
        var out = "PDF to EPUB diagnostic report\n"
        let attributes = document.documentAttributes ?? [:]
        let creator = attributes[PDFDocumentAttribute.creatorAttribute] as? String ?? "unknown"
        let producer = attributes[PDFDocumentAttribute.producerAttribute] as? String ?? "unknown"
        out += "Pages: \(document.pageCount). Made with: \(creator) / \(producer)\n"

        // Fonts, from the first pages and the page asked about.
        var fonts: [String: (font: NSFont, characters: Int)] = [:]
        var pagesWithoutFonts = 0
        let sample = Set(Array(0..<min(document.pageCount, 60)) + [pageNumber - 1])
        for index in sample.sorted() {
            guard let page = document.page(at: index), let text = page.attributedString, text.length > 0 else { continue }
            var sawFont = false
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
                guard let font = value as? NSFont else { return }
                sawFont = true
                let count = (text.string as NSString).substring(with: range).filter { !$0.isWhitespace }.count
                fonts[font.fontName, default: (font: font, characters: 0)].characters += count
            }
            if !sawFont { pagesWithoutFonts += 1 }
        }
        out += "\nFonts (name | characters | declares bold, italic | slant angle | weight | read as):\n"
        if fonts.isEmpty { out += "  none reported\n" }
        for (name, entry) in fonts.sorted(by: { $0.value.characters > $1.value.characters }) {
            let symbolic = entry.font.fontDescriptor.symbolicTraits
            let ctFont = entry.font as CTFont
            let slant = CTFontGetSlantAngle(ctFont)
            let weight = ((CTFontCopyTraits(ctFont) as? [CFString: Any])?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let read = PDFExtractor.traits(of: entry.font)
            let declared = "\(symbolic.contains(.bold) ? "bold" : "-"), \(symbolic.contains(.italic) ? "italic" : "-")"
            let readAs = [read.bold ? "bold" : nil, read.italic ? "italic" : nil].compactMap { $0 }
            out += "  \(name) | \(entry.characters) | \(declared) | \(String(format: "%.1f", slant))"
            out += " | \(String(format: "%.2f", weight)) | \(readAs.isEmpty ? "regular" : readAs.joined(separator: " "))\n"
        }
        if pagesWithoutFonts > 0 { out += "  (\(pagesWithoutFonts) pages had text without font information)\n" }

        guard pageNumber >= 1, pageNumber <= document.pageCount, let page = document.page(at: pageNumber - 1) else {
            return out + "\nThere's no page \(pageNumber); the PDF has \(document.pageCount).\n"
        }

        // The page as PDFKit reports it.
        let box = page.bounds(for: .cropBox)
        out += "\nPage \(pageNumber), \(Int(box.width))×\(Int(box.height)) pt. Letters masked: x = lower case, X = capital.\n"
        out += "Lines (top, left, width, height: [font size \"text\"] per styled run, plus any other attributes):\n"
        for line in page.selection(for: box)?.selectionsByLine() ?? [] {
            let b = line.bounds(for: page)
            var parts: [String] = []
            if let text = line.attributedString, text.length > 0 {
                text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attrs, range, _ in
                    let piece = mask((text.string as NSString).substring(with: range))
                    guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let font = attrs[.font] as? NSFont
                    let fontText = font.map { "\($0.fontName) \(String(format: "%.1f", $0.pointSize))" } ?? "no font"
                    let others = attrs.keys.map(\.rawValue).filter { $0 != NSAttributedString.Key.font.rawValue }.sorted()
                    parts.append("[\(fontText) \"\(piece.trimmingCharacters(in: .newlines))\"\(others.isEmpty ? "" : " " + others.joined(separator: ","))]")
                }
            }
            out += "  \(Int(box.maxY - b.maxY)), \(Int(b.minX - box.minX)), \(Int(b.width)), \(Int(b.height)): "
            out += parts.joined(separator: " ") + "\n"
        }

        // What the converter makes of this page and its neighbours.
        let extractor = PDFExtractor(document: document)
        var lines: [TextLine] = []
        for index in max(0, pageNumber - 2)...min(document.pageCount - 1, pageNumber) {
            if let p = document.page(at: index) { lines += extractor.textLines(on: p, index: index) }
        }
        out += "\nConverter's reading of pages \(max(1, pageNumber - 1))–\(min(document.pageCount, pageNumber + 1)):\n"
        for chapter in LayoutAnalyzer().analyze(lines: lines) {
            for block in chapter.blocks {
                switch block {
                case .heading(let level, let runs): out += "  heading \(level): \(describe(runs))\n"
                case .paragraph(let runs, _): out += "  paragraph: \(describe(runs))\n"
                case .footnote(_, let runs): out += "  footnote: \(describe(runs))\n"
                case .sceneBreak: out += "  scene break\n"
                case .image: out += "  picture\n"
                case .anchor: break
                }
            }
        }
        return out
    }

    /// Masked text of a block, with its styled parts marked: *italic*, **bold**, ^note^.
    static func describe(_ runs: [TextRun]) -> String {
        var text = ""
        for run in runs {
            var piece = mask(run.text)
            if run.italic { piece = "*\(piece)*" }
            if run.bold { piece = "**\(piece)**" }
            if run.superscript { piece = "^\(piece)^" }
            text += piece
        }
        return text.count > 120 ? String(text.prefix(120)) + "… (\(text.count) chars)" : text
    }

    static func mask(_ text: String) -> String {
        String(text.map { $0.isLetter ? ($0.isUppercase ? "X" : "x") : $0 })
    }
}
#endif
