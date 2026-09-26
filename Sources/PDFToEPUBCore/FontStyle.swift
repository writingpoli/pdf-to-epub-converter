import Foundation

/// Works out bold and italic from a font's PostScript name, for fonts that
/// don't declare their style any other way.
///
/// Book PDFs often use abbreviated names: "MinionPro-It",
/// "AGaramondPro-BoldItalic", "Sabon-Ital", "Caslon-BdIt", "Garamond,Italic",
/// often behind a subset tag ("ABCDEF+MinionPro-SemiboldIt").
public enum FontStyle {
    public static func parse(_ fontName: String) -> (bold: Bool, italic: Bool) {
        var name = fontName
        // Subset tag: six capitals and a plus sign.
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
            name = String(name[name.index(after: plus)...])
        }
        // The style is the part after the family: after a hyphen or comma, or
        // failing that the whole name (for "TimesNewRomanPS-BoldItalicMT" or
        // "GaramondItalic").
        let separators = CharacterSet(charactersIn: "-,_")
        let parts = name.components(separatedBy: separators)
        let style = (parts.count > 1 ? parts.dropFirst().joined(separator: "-") : name).lowercased()
        let whole = name.lowercased()

        let italicWords = ["italic", "ital", "oblique", "obl", "slanted", "slant", "kursiv", "cursiva", "inclined"]
        var italic = italicWords.contains { whole.contains($0) }
        // "It" as a style suffix: "-It", "-BoldIt", "-SemiboldIt", "-BdIt", "-LightIt".
        if !italic, parts.count > 1 {
            let trimmed = style.replacingOccurrences(of: "mt", with: "").replacingOccurrences(of: "std", with: "")
            italic = trimmed.hasSuffix("it") || trimmed == "i" || trimmed == "bi"
        }

        let boldWords = ["bold", "black", "heavy", "semibold", "demibold", "demi", "extrabold", "ultrabold"]
        var bold = boldWords.contains { style.contains($0) } || (parts.count == 1 && boldWords.contains { whole.contains($0) })
        // Abbreviations: "-Bd", "-BdIt", "-Sb", "-SbIt", "-B", "-BI".
        if !bold, parts.count > 1 {
            bold = style.hasPrefix("bd") || style.hasPrefix("sb") || style == "b" || style == "bi"
        }
        return (bold, italic)
    }
}

/// One font used in a PDF and how its style was read: for diagnosing
/// emphasis that goes missing. Holds no text from the book.
public struct FontReport: Codable, Equatable {
    public var name: String
    public var characters: Int
    public var bold: Bool
    public var italic: Bool

    public init(name: String, characters: Int, bold: Bool, italic: Bool) {
        self.name = name
        self.characters = characters
        self.bold = bold
        self.italic = italic
    }
}
