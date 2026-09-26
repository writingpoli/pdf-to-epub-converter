#if canImport(PDFKit)
import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// The fonts a page really uses, read from its content stream.
///
/// PDFKit sometimes reports every character in a stand-in font (a whole
/// InDesign book as "Helvetica"), which hides italics, bold and true sizes.
/// This reads the page's text operators directly: which font is set, at what
/// size and slant, and where each piece of text lands. Characters can then
/// be matched to their real font by position.
final class PDFFontMap {
    struct FontInfo {
        var name: String
        var bold: Bool
        var italic: Bool
        var twoByte: Bool
        /// Glyph widths in thousandths of an em, by character code.
        var widths: [Int: Double]
        var defaultWidth: Double
    }

    struct Span {
        var font: FontInfo
        /// Effective size in points.
        var size: Double
        /// Page-space baseline and horizontal extent.
        var baseline: Double
        var x0: Double
        var x1: Double
        var rise: Double
        /// Drawn with a slant (a regular font made to look italic).
        var slanted: Bool
        /// Drawn filled and outlined (a regular font made to look bold).
        var outlined: Bool
        var characters: Int
        /// Its place in `spans`.
        var id = 0
    }

    private(set) var spans: [Span] = []
    private var buckets: [Int: [Int]] = [:]
    private static let bucketHeight = 6.0

    init(page: PDFPage) {
        guard let cgPage = page.pageRef, let table = CGPDFOperatorTableCreate() else { return }
        let state = State()
        state.table = table
        Self.register(table)
        let stream = CGPDFContentStreamCreateWithPage(cgPage)
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)

        spans = state.spans.compactMap { span in
            var span = span
            guard span.x0.isFinite, span.x1.isFinite, span.baseline.isFinite, span.size.isFinite,
                  span.size > 0, abs(span.baseline) < 100_000 else { return nil }
            if span.x1 < span.x0 { swap(&span.x0, &span.x1) }
            return span
        }
        for i in spans.indices { spans[i].id = i }
        for (i, span) in spans.enumerated() {
            buckets[Int((span.baseline / Self.bucketHeight).rounded(.down)), default: []].append(i)
        }
    }

    /// The span of text drawn at a point on the page, if any.
    func span(at point: CGPoint) -> Span? {
        let y = Double(point.y), x = Double(point.x)
        guard x.isFinite, y.isFinite, abs(y) < 100_000 else { return nil }
        let key = Int((y / Self.bucketHeight).rounded(.down))
        var best: Span?
        var bestDistance = Double.infinity
        for k in (key - 8)...(key + 3) {
            for i in buckets[k] ?? [] {
                let span = spans[i]
                guard y >= span.baseline - span.size * 0.35, y <= span.baseline + span.size * 0.95,
                      x >= span.x0 - 0.5, x <= span.x1 + 0.5 else { continue }
                let distance = abs(y - (span.baseline + span.size * 0.3))
                if distance < bestDistance {
                    best = span
                    bestDistance = distance
                }
            }
        }
        return best
    }

    /// The pieces of text drawn along a line (baselines inside its box), left to right.
    func spansAlong(line bounds: CGRect) -> [Span] {
        let low = Double(bounds.minY) - 1, high = Double(bounds.maxY)
        let left = Double(bounds.minX) - 1, right = Double(bounds.maxX) + 1
        guard low.isFinite, high.isFinite, left.isFinite, right.isFinite, abs(low) < 100_000, abs(high) < 100_000
        else { return [] }
        var found: [Span] = []
        for k in Int((low / Self.bucketHeight).rounded(.down))...Int((high / Self.bucketHeight).rounded(.down)) {
            for i in buckets[k] ?? [] {
                let span = spans[i]
                if span.characters > 0, span.baseline >= low, span.baseline <= high, span.x1 > left, span.x0 < right {
                    found.append(span)
                }
            }
        }
        return found.sorted { $0.x0 < $1.x0 }
    }

    /// "ABCDEF+MinionPro-It" -> "MinionPro"
    static func family(of fontName: String) -> String {
        var name = fontName
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
            name = String(name[name.index(after: plus)...])
        }
        return String(name.split(whereSeparator: { $0 == "-" || $0 == "," }).first ?? Substring(name))
    }

    // MARK: - Scanning

    private struct TextState {
        var font: FontInfo?
        var size = 0.0
        var charSpacing = 0.0
        var wordSpacing = 0.0
        var scale = 1.0
        var leading = 0.0
        var rise = 0.0
        var renderMode = 0
    }

    private final class State {
        var table: CGPDFOperatorTableRef?
        var ctm = CGAffineTransform.identity
        var tm = CGAffineTransform.identity
        var tlm = CGAffineTransform.identity
        var text = TextState()
        var stack: [(CGAffineTransform, TextState)] = []
        var spans: [Span] = []
        var fonts: [OpaquePointer: FontInfo] = [:]
        var depth = 0
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> State? {
        guard let info else { return nil }
        return Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
    }

    private static func pop(_ scanner: CGPDFScannerRef) -> Double? {
        var value: CGPDFReal = 0
        return CGPDFScannerPopNumber(scanner, &value) ? Double(value) : nil
    }

    private static func popMatrix(_ scanner: CGPDFScannerRef) -> CGAffineTransform? {
        guard let f = pop(scanner), let e = pop(scanner), let d = pop(scanner),
              let c = pop(scanner), let b = pop(scanner), let a = pop(scanner) else { return nil }
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
    }

    private static func moveText(_ s: State, _ tx: Double, _ ty: Double) {
        s.tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(s.tlm)
        s.tm = s.tlm
    }

    private static func register(_ table: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let s = PDFFontMap.state(info) else { return }
            s.stack.append((s.ctm, s.text))
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let s = PDFFontMap.state(info), let (ctm, text) = s.stack.popLast() else { return }
            s.ctm = ctm
            s.text = text
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let s = PDFFontMap.state(info), let m = PDFFontMap.popMatrix(scanner) else { return }
            s.ctm = m.concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            guard let s = PDFFontMap.state(info) else { return }
            s.tm = .identity
            s.tlm = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in
            guard let s = PDFFontMap.state(info), let v = PDFFontMap.pop(scanner) else { return }
            s.text.charSpacing = v
        }
        CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in
            guard let s = PDFFontMap.state(info), let v = PDFFontMap.pop(scanner) else { return }
            s.text.wordSpacing = v
        }
        CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in
            guard let s = PDFFontMap.state(info), let v = PDFFontMap.pop(scanner) else { return }
            s.text.scale = v / 100
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            guard let s = PDFFontMap.state(info), let v = PDFFontMap.pop(scanner) else { return }
            s.text.leading = v
        }
        CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in
            guard let s = PDFFontMap.state(info), let v = PDFFontMap.pop(scanner) else { return }
            s.text.rise = v
        }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            guard let s = PDFFontMap.state(info), let v = PDFFontMap.pop(scanner) else { return }
            s.text.renderMode = PDFFontMap.integer(v) ?? 0
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            guard let s = PDFFontMap.state(info) else { return }
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { return }
            s.text.size = Double(size)
            s.text.font = PDFFontMap.font(named: name, scanner: scanner, state: s)
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let s = PDFFontMap.state(info), let ty = PDFFontMap.pop(scanner), let tx = PDFFontMap.pop(scanner) else { return }
            PDFFontMap.moveText(s, tx, ty)
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let s = PDFFontMap.state(info), let ty = PDFFontMap.pop(scanner), let tx = PDFFontMap.pop(scanner) else { return }
            s.text.leading = -ty
            PDFFontMap.moveText(s, tx, ty)
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let s = PDFFontMap.state(info), let m = PDFFontMap.popMatrix(scanner) else { return }
            s.tm = m
            s.tlm = m
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            guard let s = PDFFontMap.state(info) else { return }
            PDFFontMap.moveText(s, 0, -s.text.leading)
        }
        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            guard let s = PDFFontMap.state(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            PDFFontMap.show(string, state: s)
        }
        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            guard let s = PDFFontMap.state(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            PDFFontMap.moveText(s, 0, -s.text.leading)
            PDFFontMap.show(string, state: s)
        }
        CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
            guard let s = PDFFontMap.state(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string,
                  let charSpacing = PDFFontMap.pop(scanner), let wordSpacing = PDFFontMap.pop(scanner) else { return }
            s.text.charSpacing = charSpacing
            s.text.wordSpacing = wordSpacing
            PDFFontMap.moveText(s, 0, -s.text.leading)
            PDFFontMap.show(string, state: s)
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let s = PDFFontMap.state(info) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            for i in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var number: CGPDFReal = 0
                if CGPDFArrayGetString(array, i, &string), let string {
                    PDFFontMap.show(string, state: s)
                } else if CGPDFArrayGetNumber(array, i, &number) {
                    let tx = -Double(number) / 1000 * s.text.size * s.text.scale
                    s.tm = CGAffineTransform(translationX: tx, y: 0).concatenating(s.tm)
                }
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let s = PDFFontMap.state(info), s.depth < 4 else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            PDFFontMap.drawForm(named: name, scanner: scanner, state: s, info: info)
        }
    }

    private static func drawForm(named name: UnsafePointer<CChar>, scanner: CGPDFScannerRef, state s: State,
                                 info: UnsafeMutableRawPointer?) {
        let content = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(content, "XObject", name), let table = s.table else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
              String(cString: subtype) == "Form" else { return }

        var matrix = CGAffineTransform.identity
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
            var v = [CGFloat](repeating: 0, count: 6)
            for i in 0..<6 {
                var n: CGPDFReal = 0
                if CGPDFArrayGetNumber(array, i, &n) { v[i] = n }
            }
            matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        }
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)

        let saved = (s.ctm, s.text, s.tm, s.tlm, s.stack)
        s.ctm = matrix.concatenating(s.ctm)
        s.depth += 1
        let formContent = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
        let formScanner = CGPDFScannerCreate(formContent, table, info)
        CGPDFScannerScan(formScanner)
        CGPDFScannerRelease(formScanner)
        CGPDFContentStreamRelease(formContent)
        s.depth -= 1
        (s.ctm, s.text, s.tm, s.tlm, s.stack) = saved
    }

    private static func show(_ string: CGPDFStringRef, state s: State) {
        guard let font = s.text.font, let bytes = CGPDFStringGetBytePtr(string) else { return }
        let length = CGPDFStringGetLength(string)
        var codes: [Int] = []
        if font.twoByte {
            var i = 0
            while i + 1 < length {
                codes.append(Int(bytes[i]) << 8 | Int(bytes[i + 1]))
                i += 2
            }
        } else {
            codes = (0..<length).map { Int(bytes[$0]) }
        }
        guard !codes.isEmpty else { return }

        let t = s.text
        var advance = 0.0
        for code in codes {
            var tx = (font.widths[code] ?? font.defaultWidth) / 1000 * t.size + t.charSpacing
            if !font.twoByte && code == 32 { tx += t.wordSpacing }
            advance += tx * t.scale
        }
        let m = s.tm.concatenating(s.ctm)
        let start = CGPoint(x: 0, y: t.rise).applying(m)
        let end = CGPoint(x: advance, y: t.rise).applying(m)
        let size = t.size * Double(hypot(m.c, m.d))
        // The angle between the text's vertical and the page's: a slant.
        let xAngle = atan2(Double(m.b), Double(m.a))
        let yAngle = atan2(Double(m.d), Double(m.c))
        let slant = abs((yAngle - xAngle) * 180 / .pi - 90)
        s.spans.append(Span(font: font, size: size, baseline: Double(CGPoint(x: 0, y: 0).applying(m).y),
                            x0: Double(start.x), x1: Double(end.x), rise: t.rise * Double(hypot(m.c, m.d)),
                            slanted: slant > 5 && slant < 45, outlined: t.renderMode == 2,
                            characters: codes.count))
        s.tm = CGAffineTransform(translationX: advance, y: 0).concatenating(s.tm)
    }

    // MARK: - Fonts

    private static func font(named name: UnsafePointer<CChar>, scanner: CGPDFScannerRef, state s: State) -> FontInfo? {
        let content = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(content, "Font", name) else { return nil }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return nil }
        if let cached = s.fonts[dictionary] { return cached }
        let info = fontInfo(dictionary)
        s.fonts[dictionary] = info
        return info
    }

    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    /// A whole number from a PDF value, or nil for nonsense (a damaged file).
    static func integer(_ value: Double) -> Int? {
        value.isFinite && abs(value) < 1_000_000_000 ? Int(value) : nil
    }

    private static func number(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Double? {
        var value: CGPDFReal = 0
        return CGPDFDictionaryGetNumber(dictionary, key, &value) ? Double(value) : nil
    }

    static func fontInfo(_ dictionary: CGPDFDictionaryRef) -> FontInfo {
        let baseName = name(dictionary, "BaseFont") ?? "unnamed"
        let twoByte = name(dictionary, "Subtype") == "Type0"
        var widths: [Int: Double] = [:]
        var defaultWidth = 500.0
        var descriptor: CGPDFDictionaryRef?

        if twoByte {
            var descendants: CGPDFArrayRef?
            var cidFont: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(dictionary, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &cidFont), let cidFont {
                defaultWidth = number(cidFont, "DW") ?? 1000
                var w: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(cidFont, "W", &w), let w { parseCIDWidths(w, into: &widths) }
                CGPDFDictionaryGetDictionary(cidFont, "FontDescriptor", &descriptor)
            }
        } else {
            let first = integer(number(dictionary, "FirstChar") ?? 0) ?? 0
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Widths", &array), let array {
                for i in 0..<CGPDFArrayGetCount(array) {
                    var v: CGPDFReal = 0
                    if CGPDFArrayGetNumber(array, i, &v) { widths[first + i] = Double(v) }
                }
            }
            CGPDFDictionaryGetDictionary(dictionary, "FontDescriptor", &descriptor)
            if let descriptor, let missing = number(descriptor, "MissingWidth"), missing > 0 { defaultWidth = missing }
            if widths.isEmpty { widths = standardWidths(baseName) }
        }

        var (bold, italic) = FontStyle.parse(baseName)
        if let descriptor {
            let flags = integer(number(descriptor, "Flags") ?? 0) ?? 0
            if flags & 64 != 0 { italic = true }
            if flags & 262_144 != 0 { bold = true }
            if let angle = number(descriptor, "ItalicAngle"), abs(angle) > 4 { italic = true }
            if let weight = number(descriptor, "FontWeight"), weight >= 600 { bold = true }
        }
        return FontInfo(name: baseName, bold: bold, italic: italic, twoByte: twoByte,
                        widths: widths, defaultWidth: defaultWidth)
    }

    /// CID font widths: `[c [w1 w2 ...]]` or `[cFirst cLast w]`, repeated.
    private static func parseCIDWidths(_ array: CGPDFArrayRef, into widths: inout [Int: Double]) {
        let count = CGPDFArrayGetCount(array)
        var i = 0
        while i < count {
            var first: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(array, i, &first), (0..<16_777_216).contains(first) else { break }
            var list: CGPDFArrayRef?
            if CGPDFArrayGetArray(array, i + 1, &list), let list {
                for k in 0..<CGPDFArrayGetCount(list) {
                    var v: CGPDFReal = 0
                    if CGPDFArrayGetNumber(list, k, &v) { widths[first + k] = Double(v) }
                }
                i += 2
            } else {
                var last: CGPDFInteger = 0
                var v: CGPDFReal = 0
                guard CGPDFArrayGetInteger(array, i + 1, &last), CGPDFArrayGetNumber(array, i + 2, &v) else { break }
                if (first..<first + 65_536).contains(last) {
                    for code in first...last { widths[code] = Double(v) }
                }
                i += 3
            }
        }
    }

    /// Widths for the standard fonts (Times, Helvetica...), which PDFs may
    /// use without listing widths, measured from the Mac's copy of the font.
    private static func standardWidths(_ baseName: String) -> [Int: Double] {
        let font = CTFontCreateWithName(baseName as CFString, 1000, nil)
        var widths: [Int: Double] = [:]
        for code in 32...255 {
            var character = UniChar(code)
            var glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { continue }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            widths[code] = Double(advance.width)
        }
        return widths
    }
}
#endif
