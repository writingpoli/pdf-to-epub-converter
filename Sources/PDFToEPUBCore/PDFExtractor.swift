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

            lines.append(TextLine(runs: runs, page: index,
                                  x: Double(bounds.minX - box.minX),
                                  y: Double(box.maxY - bounds.maxY),
                                  width: Double(bounds.width), height: Double(bounds.height),
                                  fontSize: fontSize,
                                  pageWidth: Double(box.width), pageHeight: Double(box.height),
                                  fontName: familyWeights.max { $0.value < $1.value }?.key))
        }
        for i in lines.indices { lines[i].runs.markAttachedNoteMarkers() }
        addLinks(on: page, box: box, to: &lines)
        return lines
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
