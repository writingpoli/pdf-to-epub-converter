import XCTest
@testable import PDFToEPUBCore

final class FontStyleTests: XCTestCase {
    func check(_ name: String, bold: Bool, italic: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let style = FontStyle.parse(name)
        XCTAssertEqual(style.bold, bold, "\(name) bold", file: file, line: line)
        XCTAssertEqual(style.italic, italic, "\(name) italic", file: file, line: line)
    }

    func testItalicNames() {
        for name in ["Times-Italic", "MinionPro-It", "ABCDEF+MinionPro-It", "Sabon-Ital", "Helvetica-Oblique",
                     "AGaramondPro-Italic", "Garamond,Italic", "TimesNewRomanPS-ItalicMT", "Caslon-LightIt",
                     "Palatino-Kursiv", "GaramondItalic", "Frutiger-Obl"] {
            check(name, bold: false, italic: true)
        }
    }

    func testBoldNames() {
        for name in ["Times-Bold", "MinionPro-Bold", "MinionPro-Semibold", "Caslon-Bd", "Sabon-Sb",
                     "Futura-Heavy", "Gill-Demi", "TimesNewRomanPS-BoldMT", "Helvetica-Black", "Garamond,Bold"] {
            check(name, bold: true, italic: false)
        }
    }

    func testBoldItalicNames() {
        for name in ["Times-BoldItalic", "MinionPro-BoldIt", "MinionPro-SemiboldIt", "Caslon-BdIt",
                     "ABCDEF+Sabon-SbIt", "Garamond,BoldItalic", "TimesNewRomanPS-BoldItalicMT"] {
            check(name, bold: true, italic: true)
        }
    }

    func testRegularNames() {
        for name in ["Times-Roman", "MinionPro-Regular", "ABCDEF+MinionPro-Regular", "Helvetica", "Georgia",
                     "Caslon-Book", "Sabon-Roman", "Bembo", "Baskerville-Regular", "Merriweather-Light",
                     "Bitstream", "Didot"] {
            check(name, bold: false, italic: false)
        }
    }

    func testEmphasisOnMostOfTheBookIsAMisreading() {
        let lines = (0..<20).map { i in
            TextLine(runs: [TextRun(text: "Every line of this book claims to be bold and it cannot be ", bold: true),
                            TextRun(text: "right", bold: true, italic: i == 3)],
                     page: 0, x: 50, y: 60 + Double(i) * 14, width: 320, height: 12.6, fontSize: 11,
                     pageWidth: 420, pageHeight: 595)
        }
        let runs = LayoutAnalyzer.clearImplausibleEmphasis(lines).flatMap(\.runs)
        XCTAssertFalse(runs.contains(where: \.bold))
        XCTAssertEqual(runs.filter(\.italic).count, 1, "real, sparse italics stay")
    }
}
