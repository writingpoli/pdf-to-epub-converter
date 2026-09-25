import Foundation

/// Writes a `Book` as an EPUB 3 file that Apple Books (and other readers) can open.
///
/// The styling is deliberately light: no fonts, colours or alignment are forced,
/// so the reader's own theme, typeface and size settings apply.
public struct EPUBWriter {
    /// Chapters larger than this (in characters of text) are split into several
    /// files, which keeps page turns snappy in Books.
    public var maxCharactersPerFile = 150_000
    public var modifiedDate = Date()

    public init() {}

    public func write(_ book: Book, to url: URL) throws {
        try makeEPUB(book).write(to: url, options: .atomic)
    }

    public func makeEPUB(_ book: Book) -> Data {
        var zip = ZipWriter(date: modifiedDate)
        zip.add("mimetype", "application/epub+zip", compress: false)
        zip.add("META-INF/container.xml", containerXML)
        zip.add("META-INF/com.apple.ibooks.display-options.xml", appleDisplayOptions)

        let language = book.metadata.language.isEmpty ? "en" : book.metadata.language
        var manifest: [(id: String, href: String, type: String, properties: String?)] = []
        var spine: [(idref: String, linear: Bool)] = []
        var toc: [(title: String, href: String)] = []

        manifest.append(("css", "styles/book.css", "text/css", nil))
        zip.add("OEBPS/styles/book.css", stylesheet)

        var imageCounter = 0
        func addImage(_ image: BookImage, name: String? = nil, id: String? = nil, properties: String? = nil) -> String {
            imageCounter += 1
            let fileName = name ?? String(format: "image-%04d.%@", imageCounter, image.fileExtension)
            let href = "images/\(fileName)"
            manifest.append((id ?? "img\(imageCounter)", href, image.mediaType, properties))
            // Images are already compressed; storing them avoids wasted work.
            zip.add("OEBPS/\(href)", image.data, compress: false)
            return href
        }

        if let cover = book.cover {
            let href = addImage(cover, name: "cover.\(cover.fileExtension)", id: "cover-image", properties: "cover-image")
            manifest.append(("cover", "text/cover.xhtml", "application/xhtml+xml", nil))
            spine.append(("cover", true))
            zip.add("OEBPS/text/cover.xhtml", coverPage(book: book, imageHref: "../" + href, language: language))
        }

        var fileNumber = 0
        for (chapterIndex, chapter) in book.chapters.enumerated() {
            for (partIndex, blocks) in split(chapter.blocks).enumerated() {
                fileNumber += 1
                let id = String(format: "ch%03d", fileNumber)
                let href = "text/\(id).xhtml"
                var body = ""
                var previousWasParagraph = false
                for block in blocks {
                    switch block {
                    case .heading(let level, let runs):
                        body += "<h\(level)>\(inline(runs))</h\(level)>\n"
                        previousWasParagraph = false
                    case .paragraph(let runs, _):
                        let cls = previousWasParagraph ? "" : " class=\"noindent\""
                        body += "<p\(cls)>\(inline(runs))</p>\n"
                        previousWasParagraph = true
                    case .sceneBreak:
                        body += "<hr class=\"scene\"/>\n"
                        previousWasParagraph = false
                    case .image(let image, let alt):
                        let src = addImage(image)
                        body += "<figure class=\"page\"><img src=\"../\(src)\" alt=\"\(escape(alt, attribute: true))\"/></figure>\n"
                        previousWasParagraph = false
                    }
                }
                let title = partIndex == 0 ? chapter.title : "\(chapter.title) (continued)"
                zip.add("OEBPS/\(href)", xhtml(title: title, body: "<section epub:type=\"chapter\" id=\"c\(chapterIndex + 1)\">\n\(body)</section>", language: language))
                manifest.append((id, href, "application/xhtml+xml", nil))
                spine.append((id, true))
                if partIndex == 0 { toc.append((chapter.title, href)) }
            }
        }

        manifest.append(("nav", "nav.xhtml", "application/xhtml+xml", "nav"))
        zip.add("OEBPS/nav.xhtml", navDocument(toc: toc, hasCover: book.cover != nil, language: language))
        manifest.append(("ncx", "toc.ncx", "application/x-dtbncx+xml", nil))
        zip.add("OEBPS/toc.ncx", ncx(book: book, toc: toc))

        zip.add("OEBPS/content.opf", packageDocument(book: book, language: language, manifest: manifest, spine: spine))
        return zip.finalized()
    }

    // MARK: - Splitting long chapters

    func split(_ blocks: [Block]) -> [[Block]] {
        var parts: [[Block]] = [[]]
        var size = 0
        for block in blocks {
            let blockSize: Int
            switch block {
            case .heading(_, let runs), .paragraph(let runs, _): blockSize = runs.reduce(0) { $0 + $1.text.count }
            case .sceneBreak: blockSize = 0
            case .image: blockSize = 500
            }
            if size + blockSize > maxCharactersPerFile, !parts[parts.count - 1].isEmpty {
                parts.append([])
                size = 0
            }
            parts[parts.count - 1].append(block)
            size += blockSize
        }
        return parts
    }

    // MARK: - Markup

    func inline(_ runs: [TextRun]) -> String {
        var out = ""
        for run in runs {
            var text = run.text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { escape(String($0)) }
                .joined(separator: "<br/>")
            if run.italic { text = "<em>\(text)</em>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            out += text
        }
        return out
    }

    func escape(_ string: String, attribute: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            default:
                // Only characters XML 1.0 allows.
                let v = scalar.value
                let allowed = v == 0x9 || v == 0xA || v == 0xD || (0x20...0xD7FF).contains(v)
                    || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
                if allowed && !(0xFFF0...0xFFFD).contains(v) { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    func xhtml(title: String, body: String, language: String, bodyClass: String? = nil) -> String {
        let cls = bodyClass.map { " class=\"\($0)\"" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(escape(language, attribute: true))" lang="\(escape(language, attribute: true))">
        <head>
        <meta charset="UTF-8"/>
        <title>\(escape(title))</title>
        <link rel="stylesheet" type="text/css" href="../styles/book.css"/>
        </head>
        <body\(cls)>
        \(body)
        </body>
        </html>

        """
    }

    func coverPage(book: Book, imageHref: String, language: String) -> String {
        xhtml(title: book.metadata.title,
              body: "<section epub:type=\"cover\" class=\"cover\"><img src=\"\(imageHref)\" alt=\"\(escape(book.metadata.title, attribute: true))\"/></section>",
              language: language, bodyClass: "cover")
    }

    func navDocument(toc: [(title: String, href: String)], hasCover: Bool, language: String) -> String {
        let items = toc.map { "<li><a href=\"\($0.href)\">\(escape($0.title))</a></li>" }.joined(separator: "\n")
        var landmarks = ""
        if hasCover { landmarks += "<li><a epub:type=\"cover\" href=\"text/cover.xhtml\">Cover</a></li>\n" }
        if let first = toc.first { landmarks += "<li><a epub:type=\"bodymatter\" href=\"\(first.href)\">Start</a></li>\n" }
        let lang = escape(language, attribute: true)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(lang)" lang="\(lang)">
        <head><meta charset="UTF-8"/><title>Contents</title></head>
        <body>
        <nav epub:type="toc" id="toc">
        <h1>Contents</h1>
        <ol>
        \(items)
        </ol>
        </nav>
        <nav epub:type="landmarks" id="landmarks" hidden="hidden">
        <ol>
        \(landmarks)</ol>
        </nav>
        </body>
        </html>

        """
    }

    func ncx(book: Book, toc: [(title: String, href: String)]) -> String {
        let points = toc.enumerated().map { i, entry in
            """
            <navPoint id="np\(i + 1)" playOrder="\(i + 1)"><navLabel><text>\(escape(entry.title))</text></navLabel><content src="\(entry.href)"/></navPoint>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head>
        <meta name="dtb:uid" content="\(escape(book.metadata.identifier, attribute: true))"/>
        <meta name="dtb:depth" content="1"/>
        <meta name="dtb:totalPageCount" content="0"/>
        <meta name="dtb:maxPageNumber" content="0"/>
        </head>
        <docTitle><text>\(escape(book.metadata.title))</text></docTitle>
        <navMap>
        \(points)
        </navMap>
        </ncx>

        """
    }

    func packageDocument(book: Book, language: String,
                         manifest: [(id: String, href: String, type: String, properties: String?)],
                         spine: [(idref: String, linear: Bool)]) -> String {
        let m = book.metadata
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        var metadata = """
        <dc:identifier id="bookid">\(escape(m.identifier))</dc:identifier>
        <dc:title>\(escape(m.title.isEmpty ? "Untitled" : m.title))</dc:title>
        <dc:language>\(escape(language))</dc:language>
        <meta property="dcterms:modified">\(formatter.string(from: modifiedDate))</meta>

        """
        if !m.author.trimmingCharacters(in: .whitespaces).isEmpty {
            metadata += "<dc:creator id=\"creator\">\(escape(m.author))</dc:creator>\n"
            metadata += "<meta refines=\"#creator\" property=\"role\" scheme=\"marc:relators\">aut</meta>\n"
        }
        if let publisher = m.publisher, !publisher.isEmpty {
            metadata += "<dc:publisher>\(escape(publisher))</dc:publisher>\n"
        }
        if let subject = m.subject, !subject.isEmpty {
            metadata += "<dc:subject>\(escape(subject))</dc:subject>\n"
        }
        if book.cover != nil {
            metadata += "<meta name=\"cover\" content=\"cover-image\"/>\n"
        }
        let items = manifest.map { item in
            let props = item.properties.map { " properties=\"\($0)\"" } ?? ""
            return "<item id=\"\(item.id)\" href=\"\(item.href)\" media-type=\"\(item.type)\"\(props)/>"
        }.joined(separator: "\n")
        let itemrefs = spine.map { "<itemref idref=\"\($0.idref)\"\($0.linear ? "" : " linear=\"no\"")/>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(escape(language, attribute: true))">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        \(metadata)</metadata>
        <manifest>
        \(items)
        </manifest>
        <spine toc="ncx">
        \(itemrefs)
        </spine>
        </package>

        """
    }

    // MARK: - Fixed files

    let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
    </rootfiles>
    </container>

    """

    /// Lets Books use the reader's chosen font rather than treating the book as
    /// having its own typography.
    let appleDisplayOptions = """
    <?xml version="1.0" encoding="UTF-8"?>
    <display_options>
    <platform name="*">
    <option name="specified-fonts">false</option>
    </platform>
    </display_options>

    """

    let stylesheet = """
    /* Kept minimal on purpose: Apple Books applies the reader's own font, size and theme. */
    p {
      margin: 0;
      text-indent: 1.4em;
      orphans: 2;
      widows: 2;
    }
    p.noindent { text-indent: 0; }
    h1, h2, h3 {
      text-align: center;
      line-height: 1.25;
      margin: 1.6em 0 1em 0;
      page-break-after: avoid;
      -webkit-hyphens: none;
      hyphens: none;
    }
    h1 { font-size: 1.5em; margin-top: 2.5em; }
    h2 { font-size: 1.25em; }
    h3 { font-size: 1.05em; font-weight: bold; }
    h1 + h2, h1 + h3, h2 + h3 { margin-top: 0.4em; }
    hr.scene {
      border: none;
      border-top: 1px solid currentColor;
      width: 25%;
      margin: 1.4em auto;
      opacity: 0.5;
    }
    figure.page {
      margin: 1em 0;
      text-align: center;
      page-break-inside: avoid;
    }
    figure.page img {
      max-width: 100%;
      max-height: 95vh;
    }
    body.cover { margin: 0; padding: 0; text-align: center; }
    section.cover img {
      max-width: 100%;
      max-height: 100vh;
    }

    """
}
