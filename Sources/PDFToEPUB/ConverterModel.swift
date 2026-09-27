#if os(macOS)
import AppKit
import PDFKit
import PDFToEPUBCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ConverterModel: ObservableObject {
    static let shared = ConverterModel()

    enum Phase {
        case empty
        case ready
        case converting
        case finished(ConversionResult)
        case failed(String)
    }

    @Published private(set) var inputURL: URL?
    @Published private(set) var pageCount = 0
    @Published private(set) var thumbnail: NSImage?
    @Published var title = ""
    @Published var author = ""
    @Published private(set) var phase: Phase = .empty
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    /// A diagnostic report is being prepared.
    @Published private(set) var diagnosing = false

    struct Settings {
        var includeCover = true
        var recognizeScannedPages = true
        var removeHeaders = true
        var useBookmarks = true
        var keepImagePages = true
        var openInBooksWhenDone = true
    }

    private var task: Task<Void, Never>?

    var isConverting: Bool {
        if case .converting = phase { return true }
        return false
    }

    // MARK: - Input

    func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a PDF to turn into an EPUB"
        if panel.runModal() == .OK, let url = panel.url {
            load(url)
        }
    }

    func load(_ url: URL) {
        guard !isConverting else { return }
        guard let details = PDFToEPUBConverter.details(for: url) else {
            phase = .failed("“\(url.lastPathComponent)” couldn’t be opened as a PDF.")
            return
        }
        inputURL = url
        title = details.title
        author = details.author
        pageCount = details.pageCount
        thumbnail = PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox)
        progress = 0
        status = ""
        phase = .ready
    }

    // MARK: - Converting

    func convert(settings: Settings) {
        guard let inputURL, !isConverting else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.directoryURL = inputURL.deletingLastPathComponent()
        panel.nameFieldStringValue = Self.fileName(for: title.isEmpty ? inputURL.deletingPathExtension().lastPathComponent : title)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        var options = ConversionOptions()
        options.title = title
        options.author = author
        options.includeCover = settings.includeCover
        options.extraction.recognizeScannedPages = settings.recognizeScannedPages
        options.extraction.keepImagePages = settings.keepImagePages
        options.layout.removeHeadersAndFooters = settings.removeHeaders
        options.layout.useOutline = settings.useBookmarks
        let openWhenDone = settings.openInBooksWhenDone

        phase = .converting
        progress = 0
        status = "Starting…"

        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try PDFToEPUBConverter.convert(input: inputURL, output: outputURL, options: options) { fraction, message in
                    Task { @MainActor [weak self] in
                        guard let self, self.isConverting else { return }
                        self.progress = fraction
                        self.status = message
                    }
                }
                await MainActor.run { [weak self] in
                    self?.phase = .finished(result)
                    if openWhenDone { self?.openInBooks(result.outputURL) }
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in self?.phase = .ready }
            } catch {
                await MainActor.run { [weak self] in self?.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        status = "Stopping…"
    }

    // MARK: - Diagnostics

    /// Asks for a page, then copies a diagnostic report on it to the clipboard.
    func copyDiagnostics() {
        guard let inputURL else { return }
        let alert = NSAlert()
        alert.messageText = "Which page looks wrong?"
        alert.informativeText = "Enter the page number as Preview shows it, for a page where italics or a heading "
            + "come out wrong. The report copied to the clipboard shows fonts and layout, with the text masked."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "Page number"
        alert.accessoryView = field
        alert.addButton(withTitle: "Copy Report")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let page = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }

        // The report reads the whole book (for how its notes link up), which takes a while.
        diagnosing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = Diagnostics.report(for: inputURL, page: page)
            await MainActor.run {
                self?.diagnosing = false
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                let done = NSAlert()
                done.messageText = "Report copied"
                done.informativeText = "Paste it into your message to Claude. It's \(report.split(separator: "\n").count) lines long."
                done.runModal()
            }
        }
    }

    // MARK: - Results

    func openInBooks(_ url: URL) {
        let workspace = NSWorkspace.shared
        if let books = workspace.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") {
            workspace.open([url], withApplicationAt: books, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(url)
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func fileName(for title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Book" : cleaned).prefix(120)) + ".epub"
    }
}
#endif
