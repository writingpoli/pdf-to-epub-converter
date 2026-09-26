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

        // Lay out the files first, so links can say which file their target is in.
        var files: [(id: String, chapterIndex: Int, part: Int, blocks: [Block])] = []
        for (chapterIndex, chapter) in book.chapters.enumerated() {
            for (partIndex, blocks) in split(chapter.blocks).enumerated() {
                files.append((String(format: "ch%03d", files.count + 1), chapterIndex, partIndex, blocks))
            }
        }
        var targets: [String: String] = [:]   // element id -> file name
        for file in files {
            for block in file.blocks {
                switch block {
                case .anchor(let id), .footnote(let id, _): targets[id] = "\(file.id).xhtml"
                default: break
                }
                for run in block.runs ?? [] {
                    if let id = run.id { targets[id] = "\(file.id).xhtml" }
                }
            }
        }

        for file in files {
            let chapter = book.chapters[file.chapterIndex]
            let fileName = "\(file.id).xhtml"
            let href = "text/\(fileName)"
            var body = ""
            var previousWasParagraph = false
            var inList = false
            var pendingID: String?
            func idAttribute() -> String {
                defer { pendingID = nil }
                return pendingID.map { " id=\"\(escape($0, attribute: true))\"" } ?? ""
            }
            for block in file.blocks {
                // Bulleted paragraphs become a list, so wrapped lines sit under the text.
                var bulletRuns: [TextRun]?
                if case .paragraph(let runs, _) = block, let text = runs.first?.text,
                   let first = text.first, LayoutAnalyzer.bullets.contains(first) {
                    var rest = runs
                    rest[0].text = String(text.dropFirst().drop(while: \.isWhitespace))
                    bulletRuns = rest.filter { !$0.text.isEmpty }
                }
                if bulletRuns == nil, inList, !isAnchor(block) {
                    body += "</ul>\n"
                    inList = false
                }
                if let items = bulletRuns {
                    if !inList {
                        body += "<ul class=\"bullets\">\n"
                        inList = true
                    }
                    body += "<li\(idAttribute())>\(inline(items, targets: targets, file: fileName))</li>\n"
                    previousWasParagraph = false
                    continue
                }
                switch block {
                case .heading(let level, let runs):
                    body += "<h\(level)\(idAttribute())>\(inline(runs, targets: targets, file: fileName))</h\(level)>\n"
                    previousWasParagraph = false
                case .paragraph(let runs, _):
                    let cls = previousWasParagraph ? "" : " class=\"noindent\""
                    body += "<p\(idAttribute())\(cls)>\(inline(runs, targets: targets, file: fileName))</p>\n"
                    previousWasParagraph = true
                case .quote(let runs):
                    body += "<blockquote\(idAttribute())><p>\(inline(runs, targets: targets, file: fileName))</p></blockquote>\n"
                    previousWasParagraph = false
                case .sceneBreak:
                    body += "<hr\(idAttribute()) class=\"scene\"/>\n"
                    previousWasParagraph = false
                case .image(let image, let alt):
                    let src = addImage(image)
                    body += "<figure\(idAttribute()) class=\"page\"><img src=\"../\(src)\" alt=\"\(escape(alt, attribute: true))\"/></figure>\n"
                    previousWasParagraph = false
                case .anchor(let id):
                    if let waiting = pendingID { body += "<div id=\"\(escape(waiting, attribute: true))\"></div>\n" }
                    pendingID = id
                case .footnote(let id, let runs):
                    if let waiting = pendingID {
                        body += "<div id=\"\(escape(waiting, attribute: true))\"></div>\n"
                        pendingID = nil
                    }
                    body += "<aside epub:type=\"footnote\" class=\"footnote\" id=\"\(escape(id, attribute: true))\"><p>\(inline(runs, targets: targets, file: fileName))</p></aside>\n"
                    previousWasParagraph = false
                }
            }
            if inList { body += "</ul>\n" }
            if let waiting = pendingID { body += "<div id=\"\(escape(waiting, attribute: true))\"></div>\n" }
            let title = file.part == 0 ? chapter.title : "\(chapter.title) (continued)"
            zip.add("OEBPS/\(href)", xhtml(title: title, body: "<section epub:type=\"chapter\" id=\"c\(file.chapterIndex + 1)\">\n\(body)</section>", language: language))
            manifest.append((file.id, href, "application/xhtml+xml", nil))
            spine.append((file.id, true))
            if file.part == 0 { toc.append((chapter.title, href)) }
        }

        manifest.append(("nav", "nav.xhtml", "application/xhtml+xml", "nav"))
        zip.add("OEBPS/nav.xhtml", navDocument(toc: toc, hasCover: book.cover != nil, language: language))
        manifest.append(("ncx", "toc.ncx", "application/x-dtbncx+xml", nil))
        zip.add("OEBPS/toc.ncx", ncx(book: book, toc: toc))

        zip.add("OEBPS/content.opf", packageDocument(book: book, language: language, manifest: manifest, spine: spine))
        return zip.finalized()
    }

    private func isAnchor(_ block: Block) -> Bool {
        if case .anchor = block { return true }
        return false
    }

    // MARK: - Splitting long chapters

    func split(_ blocks: [Block]) -> [[Block]] {
        var parts: [[Block]] = [[]]
        var size = 0
        for block in blocks {
            let blockSize: Int
            switch block {
            case .heading(_, let runs), .paragraph(let runs, _), .quote(let runs), .footnote(_, let runs):
                blockSize = runs.reduce(0) { $0 + $1.text.count }
            case .sceneBreak, .anchor: blockSize = 0
            case .image: blockSize = 500
            }
            if size + blockSize > maxCharactersPerFile, !parts[parts.count - 1].isEmpty {
                // An anchor belongs with the block after it.
                var carried: [Block] = []
                while case .anchor = parts[parts.count - 1].last { carried.insert(parts[parts.count - 1].removeLast(), at: 0) }
                if parts[parts.count - 1].isEmpty { parts.removeLast() }
                parts.append(carried)
                size = 0
            }
            parts[parts.count - 1].append(block)
            size += blockSize
        }
        return parts
    }

    // MARK: - Markup

    /// - Parameters:
    ///   - targets: which file each element id is in; links to other ids are dropped.
    ///   - file: the file being written, so links within it need no file name.
    func inline(_ runs: [TextRun], targets: [String: String] = [:], file: String = "") -> String {
        var out = ""
        for run in runs {
            var text = run.text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { escape(String($0)) }
                .joined(separator: "<br/>")
            if run.italic { text = "<em>\(text)</em>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            if run.superscript { text = "<sup>\(text)</sup>" }
            let idAttribute = run.id.map { " id=\"\(escape($0, attribute: true))\"" } ?? ""
            var href: String?
            switch run.link {
            case .anchor(let target):
                if let targetFile = targets[target] {
                    href = (targetFile == file ? "" : targetFile) + "#" + target
                }
            case .url(let url):
                let lowered = url.lowercased()
                if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("mailto:") {
                    href = url
                }
            case .page, nil:
                break
            }
            if let href {
                let type = run.superscript && href.contains("#") ? " epub:type=\"noteref\"" : ""
                text = "<a\(idAttribute)\(type) href=\"\(escape(href, attribute: true))\">\(text)</a>"
            } else if !idAttribute.isEmpty {
                text = "<a\(idAttribute)>\(text)</a>"
            }
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
    ul.bullets {
      margin: 0.6em 0;
      padding-left: 1.4em;
    }
    ul.bullets li { margin: 0.2em 0; }
    blockquote {
      margin: 0.8em 1.5em;
    }
    blockquote p { text-indent: 0; }
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
    sup { line-height: 0; }
    sup a { text-decoration: none; }
    aside.footnote {
      font-size: 0.9em;
      margin: 0.8em 0 0 0;
    }
    aside.footnote p { text-indent: 0; }
    section.cover img {
      max-width: 100%;
      max-height: 100vh;
    }

    """
}
