#if canImport(PDFKit)
import AppKit
import Foundation
import ImageIO
import NaturalLanguage
import PDFKit
import UniformTypeIdentifiers
import Vision

public struct ExtractionOptions {
    /// Run text recognition on pages that are pictures of text (scanned books).
    public var recognizeScannedPages = true
    /// Keep illustration pages with little or no text as images.
    public var keepImagePages = true

    public init() {}
}

/// Everything the layout analyzer needs, pulled out of a PDF.
public struct ExtractedDocument {
    public var lines: [TextLine] = []
    public var pageImages: [PageImage] = []
    public var outline: [OutlineEntry] = []
    public var pageCount = 0
    public var recognizedPages: [Int] = []
    public var title: String?
    public var author: String?
    public var subject: String?
    public var language: String?
}

public final class PDFExtractor {
    public let document: PDFDocument

    public init(document: PDFDocument) {
        self.document = document
    }

    // MARK: - Whole document

    public func extract(options: ExtractionOptions = ExtractionOptions(),
                        progress: (Int, Int) -> Void = { _, _ in }) throws -> ExtractedDocument {
        var result = ExtractedDocument()
        result.pageCount = document.pageCount
        let attributes = document.documentAttributes ?? [:]
        result.title = Self.nonEmpty(attributes[PDFDocumentAttribute.titleAttribute] as? String)
        result.author = Self.nonEmpty(attributes[PDFDocumentAttribute.authorAttribute] as? String)
        result.subject = Self.nonEmpty(attributes[PDFDocumentAttribute.subjectAttribute] as? String)
        result.outline = outlineEntries()

        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            progress(index, document.pageCount)
            try autoreleasepool {
                guard let page = document.page(at: index) else { return }
                var lines = textLines(on: page, index: index)
                let characters = lines.reduce(0) { $0 + $1.text.count }
                let hasPictures = hasSizableImages(page)

                if characters < 20 {
                    if options.recognizeScannedPages && (hasPictures || characters == 0) {
                        try Task.checkCancellation()
                        let recognized = recognizeText(on: page, index: index)
                        let recognizedCharacters = recognized.reduce(0) { $0 + $1.text.count }
                        if recognizedCharacters >= 40 || (!hasPictures && recognizedCharacters > 0) {
                            lines = recognized
                            result.recognizedPages.append(index)
                        } else if hasPictures && options.keepImagePages {
                            lines = []
                            if let image = pageImage(page) {
                                result.pageImages.append(PageImage(page: index, image: image,
                                                                   altText: "Illustration from page \(index + 1)"))
                            }
                        }
                    } else if hasPictures && options.keepImagePages {
                        lines = []
                        if let image = pageImage(page) {
                            result.pageImages.append(PageImage(page: index, image: image,
                                                               altText: "Illustration from page \(index + 1)"))
                        }
                    }
                } else if hasPictures && characters < 120 && options.keepImagePages {
                    // A plate or figure with a short caption: the picture carries the page.
                    let caption = lines.map(\.text).joined(separator: " ")
                    lines = []
                    if let image = pageImage(page) {
                        result.pageImages.append(PageImage(page: index, image: image, altText: caption))
                    }
                }
                result.lines.append(contentsOf: lines)
            }
        }
        progress(document.pageCount, document.pageCount)
        result.language = Self.detectLanguage(result.lines)
        return result
    }

    // MARK: - Text

    func textLines(on page: PDFPage, index: Int) -> [TextLine] {
        let box = page.bounds(for: .cropBox)
        guard let selection = page.selection(for: box) else { return [] }
        let fontMap = PDFFontMap(page: page)
        let pageText = (page.string ?? "") as NSString
        var drift = 0
        var lines: [TextLine] = []
        for lineSelection in selection.selectionsByLine() {
            guard let string = lineSelection.string,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let bounds = lineSelection.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { continue }

            var runs: [TextRun] = []
            var runSizes: [Double?] = []
            var sizeWeights: [Double: Int] = [:]
            var familyWeights: [String: Int] = [:]
            if let attributed = lineSelection.attributedString, attributed.length > 0 {
                attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attrs, range, _ in
                    let text = (attributed.string as NSString).substring(with: range)
                    let font = attrs[.font] as? NSFont
                    let traits = Self.traits(of: font)
                    if let font {
                        let letters = text.filter { !$0.isWhitespace }.count
                        self.fonts[font.fontName, default: FontReport(name: font.fontName, characters: 0,
                                                                      bold: traits.bold, italic: traits.italic)]
                            .characters += letters
                    }
                    let raised = (attrs[NSAttributedString.Key("NSSuperScript")] as? Int ?? 0) > 0
                        || (attrs[.baselineOffset] as? Double ?? 0) > 0.5
                    runs.append(TextRun(text: text, bold: traits.bold, italic: traits.italic,
                                        superscript: raised && Self.isMarkerText(text)))
                    runSizes.append(font.map { Double($0.pointSize) })
                    if let family = font?.familyName {
                        familyWeights[family, default: 0] += text.filter { !$0.isWhitespace }.count
                    }
                    if let font, font.pointSize > 1 {
                        let letters = text.filter { !$0.isWhitespace }.count
                        sizeWeights[Double(font.pointSize), default: 0] += max(1, letters)
                    }
                }
            } else {
                runs = [TextRun(text: string)]
            }

            let heightEstimate = Double(bounds.height) / 1.15
            var fontSize = sizeWeights.max { $0.value < $1.value }?.key ?? heightEstimate
            let ratio = fontSize / max(heightEstimate, 0.1)
            if ratio < 0.55 || ratio > 1.7 { fontSize = heightEstimate }

            // Note references: numbers or symbols set noticeably smaller than the line.
            for i in runs.indices where i < runSizes.count {
                guard let size = runSizes[i], size < fontSize * 0.8 else { continue }
                if Self.isMarkerText(runs[i].text) { runs[i].superscript = true }
            }

            var fontName = familyWeights.max { $0.value < $1.value }?.key
            // PDFKit can report stand-in fonts (a whole book in "Helvetica");
            // the page's own drawing instructions say which font really drew what.
            linesSeen += 1
            if let real = realFonts(for: string, selection: lineSelection, bounds: bounds, page: page,
                                    pageText: pageText, map: fontMap, drift: &drift) {
                runs = real.runs
                fontSize = real.size
                fontName = real.family
                linesMatched += 1
                let text = string.trimmingCharacters(in: .newlines) as NSString
                addMissingMarkers(to: &runs, bounds: bounds, size: fontSize, map: fontMap, covered: real.spansUsed) { span in
                    // After the last character drawn before the marker.
                    guard let k = real.characterRight.lastIndex(where: { ($0 ?? .infinity) <= CGFloat(span.x0) + 1 })
                    else { return 0 }
                    return (text.substring(to: k + 1) as String).count
                }
            } else if let estimate = estimatedFonts(for: string, bounds: bounds, map: fontMap) {
                runs = estimate.runs
                fontSize = estimate.size
                fontName = estimate.family
                linesEstimated += 1
                let text = Array(runs.joinedText)
                addMissingMarkers(to: &runs, bounds: bounds, size: fontSize, map: fontMap, covered: []) { span in
                    // Roughly where along the line it was drawn, at the nearest word end,
                    // unless the text already has a number there.
                    let fraction = (span.x0 - Double(bounds.minX)) / max(1, Double(bounds.width))
                    let guess = min(text.count, max(0, Int((fraction * Double(text.count)).rounded())))
                    let ends = (1...max(1, text.count)).filter { i in
                        i <= text.count && !text[i - 1].isWhitespace && (i == text.count || text[i].isWhitespace)
                    }
                    guard let at = ends.min(by: { abs($0 - guess) < abs($1 - guess) }) else { return nil }
                    let near = text[max(0, at - 3)..<min(text.count, at + 2)]
                    return near.contains(where: \.isNumber) ? nil : at
                }
            } else if !fontMap.spans.isEmpty {
                // The page's real fonts are known but this line couldn't be
                // matched to one; PDFKit's stand-in ("Helvetica") would make it
                // look like a different typeface, and so a heading.
                fontName = nil
            }

            lines.append(TextLine(runs: runs, page: index,
                                  x: Double(bounds.minX - box.minX),
                                  y: Double(box.maxY - bounds.maxY),
                                  width: Double(bounds.width), height: Double(bounds.height),
                                  fontSize: fontSize,
                                  pageWidth: Double(box.width), pageHeight: Double(box.height),
                                  fontName: fontName))
        }
        for i in lines.indices { lines[i].runs.markAttachedNoteMarkers() }
        addLinks(on: page, box: box, to: &lines)
        return lines
    }

    /// Fonts found in the pages' drawing instructions, with how each was read.
    public private(set) var drawnFonts: [String: FontReport] = [:]
    /// Lines read so far, and how many were matched to the fonts that drew them.
    public private(set) var linesSeen = 0
    public private(set) var linesMatched = 0
    /// Lines whose fonts were worked out from the order of the text drawn along them.
    public private(set) var linesEstimated = 0
    /// Note numbers found drawn but missing from PDFKit's text.
    public private(set) var markersRecovered = 0

    /// Note numbers drawn small and raised that PDFKit's text leaves out
    /// (InDesign's superscript figures can have no text behind them). Each
    /// becomes a "*" note marker where it was drawn; endnote linking numbers
    /// it from its place in the sequence.
    func addMissingMarkers(to runs: inout [TextRun], bounds: CGRect, size: Double, map: PDFFontMap,
                           covered: Set<Int>, position: (PDFFontMap.Span) -> Int?) {
        // A marker PDFKit left out at the end of a line lies past the line's box.
        let drawn = map.spansAlong(line: bounds, reachRight: size * 1.2)
        var baselines: [Double: Int] = [:]
        for span in drawn where abs(span.size - size) < 0.5 { baselines[span.baseline.rounded(), default: 0] += span.characters }
        guard let baseline = baselines.max(by: { $0.value < $1.value })?.key else { return }
        let markers = drawn.filter { span in
            !covered.contains(span.id) && (1...3).contains(span.characters) && span.size < size * 0.85
                && (span.rise > 0.5 || span.baseline > baseline + size * 0.15)
        }
        // Right to left, so earlier positions stay put.
        for span in markers.sorted(by: { $0.x0 > $1.x0 }) {
            guard let at = position(span) else { continue }
            // PDFKit's text may have it after all, a few characters off: a number
            // or a raised run right there means it isn't missing.
            var offset = 0
            var nearby = false
            for run in runs {
                let range = offset..<(offset + run.text.count)
                if range.overlaps((at - 3)..<(at + 3)) && (run.superscript || run.text.contains(where: \.isNumber)) {
                    let chars = Array(run.text)
                    nearby = run.superscript || (max(at - 3, offset)..<min(at + 3, range.upperBound)).contains { i in
                        i - offset < chars.count && chars[i - offset].isNumber
                    }
                    if nearby { break }
                }
                offset += run.text.count
            }
            guard !nearby else { continue }
            runs.insert(TextRun(text: "*", superscript: true), atCharacter: at)
            markersRecovered += 1
        }
    }

    /// For a line whose characters couldn't be matched one by one: the pieces
    /// of text drawn along it, left to right, and how many characters each
    /// drew, say roughly which characters are in which font. Each word then
    /// takes the style most of its characters have, so a count that's off by
    /// a ligature or two doesn't spill italics onto the next word.
    func estimatedFonts(for text: String, bounds: CGRect, map: PDFFontMap) -> (runs: [TextRun], size: Double, family: String?)? {
        let line = text.trimmingCharacters(in: .newlines) as NSString
        let drawn = map.spansAlong(line: bounds)
        let total = drawn.reduce(0) { $0 + $1.characters }
        guard line.length > 0, total > 0, abs(total - line.length) <= max(3, line.length / 6) else { return nil }
        var owner: [Int] = []
        for (i, span) in drawn.enumerated() { owner += Array(repeating: i, count: span.characters) }
        let scale = Double(owner.count) / Double(line.length)

        var sizes: [Double: Int] = [:], families: [String: Int] = [:]
        for span in drawn {
            sizes[(span.size * 2).rounded() / 2, default: 0] += span.characters
            families[PDFFontMap.family(of: span.font.name), default: 0] += span.characters
            drawnFonts[span.font.name, default: FontReport(name: span.font.name, characters: 0,
                                                           bold: span.font.bold || span.outlined,
                                                           italic: span.font.italic || span.slanted)].characters += span.characters
        }
        guard let size = sizes.max(by: { $0.value < $1.value })?.key else { return nil }
        let baseline = drawn.filter { abs($0.size - size) < 0.5 }.map(\.baseline).max() ?? drawn[0].baseline

        func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 || unit == 0xA0 }
        struct Style: Equatable { var bold = false, italic = false, raised = false }
        var styles = (0..<line.length).map { k -> Style in
            let span = drawn[owner[min(owner.count - 1, Int((Double(k) + 0.5) * scale))]]
            let raised = span.rise > 0.5 || (span.size < size * 0.85 && span.baseline > baseline + size * 0.15)
            let piece = line.substring(with: NSRange(location: k, length: 1))
            return Style(bold: span.font.bold || span.outlined, italic: span.font.italic || span.slanted,
                         raised: raised && Self.isMarkerText(piece))
        }
        // Each word takes its majority style (ties go to the plainer one); raised
        // note numbers keep their own.
        var k = 0
        while k < line.length {
            guard !isSpace(line.character(at: k)) else { k += 1; continue }
            var end = k
            while end < line.length, !isSpace(line.character(at: end)) { end += 1 }
            let word = (k..<end).filter { !styles[$0].raised }
            if !word.isEmpty {
                let bold = word.filter { styles[$0].bold }.count * 2 > word.count
                let italic = word.filter { styles[$0].italic }.count * 2 > word.count
                for i in word { styles[i].bold = bold; styles[i].italic = italic }
            }
            k = end
        }
        // Spaces take the plainer style of the words either side.
        for i in 0..<line.length where isSpace(line.character(at: i)) {
            let before = i > 0 ? styles[i - 1] : nil
            let after = i + 1 < line.length ? styles[i + 1] : nil
            var style = Style()
            if let before, let after {
                style.bold = before.bold && after.bold
                style.italic = before.italic && after.italic
            } else if let only = before ?? after {
                style.bold = only.bold
                style.italic = only.italic
            }
            styles[i] = style
        }

        var runs: [TextRun] = []
        var runStart = 0
        for i in 1...styles.count where i == styles.count || styles[i] != styles[runStart] {
            let piece = line.substring(with: NSRange(location: runStart, length: i - runStart))
            let style = styles[runStart]
            runs.append(TextRun(text: piece, bold: style.bold, italic: style.italic, superscript: style.raised))
            runStart = i
        }
        return (runs, size, families.max(by: { $0.value < $1.value })?.key)
    }

    /// Rebuilds a line's styled runs from the fonts that really drew each
    /// character. Returns nil when too little of the line can be matched up.
    func realFonts(for text: String, selection: PDFSelection, bounds: CGRect, page: PDFPage, pageText: NSString,
                   map: PDFFontMap, drift: inout Int)
        -> (runs: [TextRun], size: Double, family: String?, spansUsed: Set<Int>, characterRight: [CGFloat?])? {
        guard !map.spans.isEmpty else { return nil }
        let line = text.trimmingCharacters(in: .newlines) as NSString
        guard line.length > 0, pageText.length >= line.length else { return nil }

        // Which of PDFKit's character numbers make up this line. The line's
        // selection says so directly; the page text search and the position
        // hint are fallbacks. PDFKit's text and its character positions can
        // count differently (the gap grows down the page), so each candidate
        // is checked by where its first and last characters actually sit.
        let characterCount = page.numberOfCharacters
        func characterBox(_ index: Int) -> CGRect? {
            index >= 0 && index < characterCount ? page.characterBounds(at: index) : nil
        }
        func usable(_ r: CGRect) -> Bool {
            !r.isNull && !r.isInfinite && r.minX.isFinite && r.minY.isFinite && (r.width > 0 || r.height > 0)
        }
        func inLine(_ r: CGRect) -> Bool {
            r.midY >= bounds.minY - 1 && r.midY <= bounds.maxY + 1
                && r.midX >= bounds.minX - 2 && r.midX <= bounds.maxX + 2
        }
        var bases: [Int] = []
        if selection.numberOfTextRanges(on: page) > 0 {
            bases.append(selection.range(at: 0, on: page).location)
        }
        let rawHint = page.characterIndex(at: CGPoint(x: bounds.minX + 1, y: bounds.midY))
        if rawHint >= 0 && rawHint < characterCount { bases.append(rawHint) }
        let found = pageText.range(of: line as String, options: [.literal]).location
        if found != NSNotFound {
            bases.append(found + drift)
            bases.append(found)
        }
        bases = bases.filter { $0 >= 0 && $0 < characterCount }
        let lastInk = (0..<line.length).last { k in
            let unit = line.character(at: k)
            return unit != 32 && unit != 9 && unit != 0xA0
        } ?? line.length - 1
        let firstInk = (0..<line.length).first { k in
            let unit = line.character(at: k)
            return unit != 32 && unit != 9 && unit != 0xA0
        } ?? 0
        var best: (start: Int, score: CGFloat)?
        for base in bases {
            for offset in -3...3 {
                let candidate = base + offset
                guard let a = characterBox(candidate + firstInk), let b = characterBox(candidate + lastInk),
                      usable(a), usable(b), inLine(a), inLine(b) else { continue }
                let score = abs(a.minX - bounds.minX) + abs(b.maxX - bounds.maxX)
                if score < (best?.score ?? .infinity) { best = (candidate, score) }
            }
            if let best, best.score < 1 { break }
        }
        guard let best, best.score < max(3, bounds.height * 0.4) else { return nil }
        let start = best.start
        if found != NSNotFound { drift = start - found }

        struct Style: Equatable {
            var bold: Bool
            var italic: Bool
            var raised: Bool
        }
        var spans: [PDFFontMap.Span?] = []
        var characterRight: [CGFloat?] = []
        var letters = 0, matched = 0
        for k in 0..<line.length {
            let box = characterBox(start + k).flatMap { usable($0) && inLine($0) ? $0 : nil }
            characterRight.append(box?.maxX)
            let unit = line.character(at: k)
            if unit == 32 || unit == 9 || unit == 0xA0 {
                spans.append(nil)
                continue
            }
            letters += 1
            let span = box.flatMap { r in map.span(at: CGPoint(x: r.midX, y: r.midY)) }
            if span != nil { matched += 1 }
            spans.append(span)
        }
        guard letters > 0, Double(matched) >= Double(letters) * 0.8 else { return nil }

        // The line's main size, baseline and typeface.
        var sizes: [Double: Int] = [:], families: [String: Int] = [:], baselines: [Double: Int] = [:]
        for span in spans.compactMap({ $0 }) {
            sizes[(span.size * 2).rounded() / 2, default: 0] += 1
            families[PDFFontMap.family(of: span.font.name), default: 0] += 1
            baselines[span.baseline.rounded(), default: 0] += 1
            let style = (span.font.bold || span.outlined, span.font.italic || span.slanted)
            drawnFonts[span.font.name, default: FontReport(name: span.font.name, characters: 0,
                                                           bold: style.0, italic: style.1)].characters += 1
        }
        guard let size = sizes.max(by: { $0.value < $1.value })?.key,
              let baseline = baselines.max(by: { $0.value < $1.value })?.key else { return nil }

        // Group characters into runs of one style.
        var styles: [Style?] = spans.map { span in
            guard let span else { return nil }
            let raised = span.rise > 0.5
                || (span.size < size * 0.85 && span.baseline > baseline + size * 0.15)
            return Style(bold: span.font.bold || span.outlined, italic: span.font.italic || span.slanted, raised: raised)
        }
        // A space (or unmatched character) takes the style around it; between
        // two styles, the plainer one, so "an *italic* word" keeps its spaces roman.
        func weight(_ style: Style) -> Int { (style.bold ? 1 : 0) + (style.italic ? 1 : 0) + (style.raised ? 1 : 0) }
        let known = styles
        for i in styles.indices where known[i] == nil {
            let before = known[..<i].last { $0 != nil } ?? nil
            let after = known[(i + 1)...].first { $0 != nil } ?? nil
            switch (before, after) {
            case let (b?, a?): styles[i] = b == a ? b : (weight(a) < weight(b) ? a : b)
            case let (b?, nil): styles[i] = b
            case let (nil, a?): styles[i] = a
            default: styles[i] = nil
            }
        }

        var runs: [TextRun] = []
        var runStart = 0
        for i in 1...styles.count where i == styles.count || styles[i] != styles[runStart] {
            let piece = line.substring(with: NSRange(location: runStart, length: i - runStart))
            let style = styles[runStart] ?? Style(bold: false, italic: false, raised: false)
            runs.append(TextRun(text: piece, bold: style.bold, italic: style.italic,
                                superscript: style.raised && Self.isMarkerText(piece)))
            runStart = i
        }
        return (runs, size, families.max(by: { $0.value < $1.value })?.key,
                Set(spans.compactMap { $0?.id }), characterRight)
    }

    /// Carries the PDF's own links (contents entries, note references, web
    /// addresses) over to the words they cover.
    func addLinks(on page: PDFPage, box: CGRect, to lines: inout [TextLine]) {
        for annotation in page.annotations where annotation.type == "Link" {
            let link: Link
            let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
            if let destination, let target = destination.page {
                link = .page(document.index(for: target), y: topY(of: destination, on: target))
            } else if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
                link = .url(url.absoluteString)
            } else {
                continue
            }
            let bounds = annotation.bounds
            guard let linked = page.selection(for: bounds)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines), !linked.isEmpty else { continue }
            let top = Double(box.maxY - bounds.maxY), bottom = Double(box.maxY - bounds.minY)
            let left = Double(bounds.minX - box.minX), right = Double(bounds.maxX - box.minX)
            let hits = lines.indices.filter { i in
                lines[i].y < bottom && lines[i].maxY > top && lines[i].x < right && lines[i].maxX > left
            }
            let linkedKey = linked.filter { !$0.isWhitespace }
            for i in hits {
                // A note number: prefer the superscript run that reads the same.
                if let r = lines[i].runs.firstIndex(where: {
                    $0.superscript && $0.link == nil && $0.text.trimmingCharacters(in: .whitespaces) == linked
                }) {
                    lines[i].runs[r].link = link
                    continue
                }
                if lines[i].addLink(link, text: linked) { continue }
                let lineKey = lines[i].text.filter { !$0.isWhitespace }
                let overlap = min(lines[i].maxX, right) - max(lines[i].x, left)
                if (!lineKey.isEmpty && linkedKey.contains(lineKey)) || overlap >= lines[i].width * 0.8 {
                    lines[i].runs = lines[i].runs.map { run in
                        var run = run
                        if run.link == nil { run.link = link }
                        return run
                    }
                }
            }
        }
    }

    /// Distance from the top of the page a destination points at, if it names one.
    func topY(of destination: PDFDestination, on page: PDFPage) -> Double? {
        let box = page.bounds(for: .cropBox)
        let pointY = destination.point.y
        guard pointY != kPDFDestinationUnspecifiedValue, pointY.isFinite,
              pointY >= box.minY - 1, pointY <= box.maxY + 1 else { return nil }
        return Double(box.maxY - pointY)
    }

    /// A note number or symbol: "3", "12", "*", "†".
    static func isMarkerText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.count <= 3 && (t.allSatisfy(\.isNumber) || t.allSatisfy { "*†‡§¶".contains($0) })
    }

    /// Bold and italic, from what the font declares, from its design (slant
    /// angle and weight), or failing those from its name ("MinionPro-It").
    static func traits(of font: NSFont?) -> (bold: Bool, italic: Bool) {
        guard let font else { return (false, false) }
        let symbolic = font.fontDescriptor.symbolicTraits
        let named = FontStyle.parse(font.fontName)
        let ctFont = font as CTFont
        let slanted = abs(CTFontGetSlantAngle(ctFont)) > 4
        var heavy = false
        if let traits = CTFontCopyTraits(ctFont) as? [CFString: Any],
           let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue {
            heavy = weight >= 0.3
        }
        return (symbolic.contains(.bold) || heavy || named.bold,
                symbolic.contains(.italic) || slanted || named.italic)
    }

    /// Every font met so far, with how its style was read.
    public private(set) var fonts: [String: FontReport] = [:]

    // MARK: - Scanned pages

    func recognizeText(on page: PDFPage, index: Int) -> [TextLine] {
        guard let image = render(page, maxDimension: 2600) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        let size = displaySize(of: page)
        let observations = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        return observations.compactMap { observation -> TextLine? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let r = observation.boundingBox
            let height = Double(r.height * size.height)
            return TextLine(runs: [TextRun(text: candidate.string)], page: index,
                            x: Double(r.minX * size.width), y: Double((1 - r.maxY) * size.height),
                            width: Double(r.width * size.width), height: height,
                            fontSize: height / 1.15,
                            pageWidth: Double(size.width), pageHeight: Double(size.height))
        }
    }

    // MARK: - Images

    func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    public func render(_ page: PDFPage, maxDimension: CGFloat) -> CGImage? {
        let size = displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxDimension / max(size.width, size.height), 4)
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    public func pageImage(_ page: PDFPage, maxDimension: CGFloat = 1800) -> BookImage? {
        guard let image = render(page, maxDimension: maxDimension),
              let data = Self.jpeg(image, quality: 0.82) else { return nil }
        return BookImage(data: data, mediaType: "image/jpeg", pixelWidth: image.width, pixelHeight: image.height)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Whether the page draws a raster image big enough to matter (a scan, a
    /// photo, a plate), as opposed to having none or only tiny ornaments.
    ///
    /// Many PDFs share one resource dictionary between every page and every
    /// embedded graphic, so each XObject dictionary is examined once per
    /// document and the answer cached. Walking it afresh from every graphic
    /// that refers back to it grows as the cube of its size and can hang.
    func hasSizableImages(_ page: PDFPage) -> Bool {
        guard let dictionary = page.pageRef?.dictionary else { return false }
        var visiting = Set<OpaquePointer>()
        return containsSizableImage(resourcesOf: dictionary, depth: 0, visiting: &visiting)
    }

    private var xObjectCache: [OpaquePointer: Bool] = [:]

    private func containsSizableImage(resourcesOf dictionary: CGPDFDictionaryRef, depth: Int,
                                      visiting: inout Set<OpaquePointer>) -> Bool {
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return false }
        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return false }
        if let cached = xObjectCache[xObjects] { return cached }
        guard depth < 3, visiting.insert(xObjects).inserted else { return false }
        defer { visiting.remove(xObjects) }

        var found = false
        var forms: [CGPDFDictionaryRef] = []
        CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image":
                var width: CGPDFInteger = 0
                var height: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(streamDictionary, "Width", &width)
                CGPDFDictionaryGetInteger(streamDictionary, "Height", &height)
                if width >= 150 && height >= 150 { found = true }
            case "Form":
                forms.append(streamDictionary)
            default:
                break
            }
            return !found
        }, nil)

        if !found {
            for form in forms where containsSizableImage(resourcesOf: form, depth: depth + 1, visiting: &visiting) {
                found = true
                break
            }
        }
        xObjectCache[xObjects] = found
        return found
    }

    // MARK: - Outline

    func outlineEntries() -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var entries: [OutlineEntry] = []
        func walk(_ node: PDFOutline, level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                if let destination, let page = destination.page {
                    let index = document.index(for: page)
                    let y = topY(of: destination, on: page)
                    let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        entries.append(OutlineEntry(title: title, page: index, y: y, level: level))
                    }
                }
                if level < 3 { walk(child, level: level + 1) }
            }
        }
        walk(root, level: 0)
        return entries
    }

    // MARK: - Helpers

    static func detectLanguage(_ lines: [TextLine]) -> String? {
        var sample = ""
        for line in lines where sample.count < 6000 { sample += line.text + " " }
        guard sample.count > 200 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }

    static func nonEmpty(_ string: String?) -> String? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
#endif
