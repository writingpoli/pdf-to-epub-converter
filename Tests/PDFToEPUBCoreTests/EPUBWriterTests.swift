import XCTest
@testable import PDFToEPUBCore

final class EPUBWriterTests: XCTestCase {
    func sampleBook(cover: Bool = false) -> Book {
        let image = BookImage(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), mediaType: "image/jpeg", pixelWidth: 1, pixelHeight: 1)
        return Book(metadata: BookMetadata(title: "Tom & Jerry <Tales>", author: "A. Writer"),
                    cover: cover ? image : nil,
                    chapters: [
                        Chapter(title: "One", blocks: [
                            .heading(level: 1, runs: [TextRun(text: "One")]),
                            .paragraph([TextRun(text: "Plain "), TextRun(text: "slanted", italic: true),
                                        TextRun(text: " & bold", bold: true)], indented: false),
                            .sceneBreak,
                            .paragraph([TextRun(text: "Line one\nline two")], indented: true),
                        ]),
                        Chapter(title: "Two", blocks: [.image(image, alt: "A \"quoted\" picture")]),
                    ])
    }

    /// Reads a stored or deflated ZIP's central directory: name -> (method, local header offset).
    func entries(_ data: Data) -> [(name: String, method: UInt16, offset: Int)] {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard let eocd = stride(from: bytes.count - 22, through: 0, by: -1).first(where: { u32($0) == 0x0605_4b50 })
        else { return [] }
        var position = u32(eocd + 16)
        var result: [(String, UInt16, Int)] = []
        for _ in 0..<u16(eocd + 10) {
            XCTAssertEqual(u32(position), 0x0201_4b50)
            let nameLength = u16(position + 28)
            let extra = u16(position + 30)
            let comment = u16(position + 32)
            let name = String(decoding: bytes[(position + 46)..<(position + 46 + nameLength)], as: UTF8.self)
            result.append((name, UInt16(u16(position + 10)), u32(position + 42)))
            position += 46 + nameLength + extra + comment
        }
        return result
    }

    func storedText(_ data: Data, _ name: String) -> String? {
        let bytes = [UInt8](data)
        guard let entry = entries(data).first(where: { $0.name == name }), entry.method == 0 else { return nil }
        let o = entry.offset
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        let size = u16(o + 18) | u16(o + 20) << 16
        let start = o + 30 + u16(o + 26) + u16(o + 28)
        return String(decoding: bytes[start..<(start + size)], as: UTF8.self)
    }

    func testMimetypeComesFirstAndUncompressed() {
        let data = EPUBWriter().makeEPUB(sampleBook())
        let first = entries(data).first
        XCTAssertEqual(first?.name, "mimetype")
        XCTAssertEqual(first?.method, 0)
        XCTAssertEqual(first?.offset, 0)
        XCTAssertEqual(String(decoding: data[38..<58], as: UTF8.self), "application/epub+zip")
    }

    func testContainsRequiredFiles() {
        let names = Set(entries(EPUBWriter().makeEPUB(sampleBook(cover: true))).map(\.name))
        for required in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/toc.ncx",
                         "OEBPS/text/cover.xhtml", "OEBPS/text/ch001.xhtml", "OEBPS/text/ch002.xhtml",
                         "OEBPS/images/cover.jpg", "OEBPS/styles/book.css"] {
            XCTAssertTrue(names.contains(required), "missing \(required)")
        }
    }

    func testMarkupIsEscapedAndStyled() {
        let writer = EPUBWriter()
        XCTAssertEqual(writer.inline([TextRun(text: "a < b & c", italic: true)]), "<em>a &lt; b &amp; c</em>")
        XCTAssertEqual(writer.inline([TextRun(text: "x\ny")]), "x<br/>y")
        XCTAssertEqual(writer.escape("say \"hi\"", attribute: true), "say &quot;hi&quot;")
        XCTAssertEqual(writer.escape("bad\u{0001}char"), "badchar")
    }

    func testChapterFileContent() throws {
        #if canImport(Compression)
        throw XCTSkip("Entries are deflated on Apple platforms; covered by the conversion test there.")
        #else
        let data = EPUBWriter().makeEPUB(sampleBook())
        let chapter = try XCTUnwrap(storedText(data, "OEBPS/text/ch001.xhtml"))
        XCTAssertTrue(chapter.contains("<p class=\"noindent\">Plain <em>slanted</em><strong> &amp; bold</strong></p>"), chapter)
        XCTAssertTrue(chapter.contains("<hr class=\"scene\"/>"))
        XCTAssertTrue(chapter.contains("<p class=\"noindent\">Line one<br/>line two</p>"), chapter)
        let opf = try XCTUnwrap(storedText(data, "OEBPS/content.opf"))
        XCTAssertTrue(opf.contains("<dc:title>Tom &amp; Jerry &lt;Tales&gt;</dc:title>"), opf)
        XCTAssertTrue(opf.contains("<dc:creator id=\"creator\">A. Writer</dc:creator>"))
        #endif
    }

    func testLongChaptersAreSplitAcrossFiles() {
        var writer = EPUBWriter()
        writer.maxCharactersPerFile = 100
        let paragraph = Block.paragraph([TextRun(text: String(repeating: "word ", count: 12))], indented: false)
        let book = Book(metadata: BookMetadata(title: "Long"),
                        chapters: [Chapter(title: "Only", blocks: Array(repeating: paragraph, count: 5))])
        let names = entries(writer.makeEPUB(book)).map(\.name).filter { $0.hasPrefix("OEBPS/text/") }
        XCTAssertEqual(names.count, 5)
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }
}
