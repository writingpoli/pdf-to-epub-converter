#if os(macOS)
import PDFToEPUBCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: ConverterModel
    @State private var isDropTargeted = false

    @AppStorage("includeCover") private var includeCover = true
    @AppStorage("recognizeScannedPages") private var recognizeScannedPages = true
    @AppStorage("removeHeaders") private var removeHeaders = true
    @AppStorage("useBookmarks") private var useBookmarks = true
    @AppStorage("keepImagePages") private var keepImagePages = true
    @AppStorage("openInBooks") private var openInBooksWhenDone = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.inputURL == nil {
                dropZone
            } else {
                bookDetails
                Divider()
                optionsSection
                Divider()
                footer
            }
        }
        .padding(22)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            if isDropTargeted && model.inputURL != nil {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    // MARK: - Empty state

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "book")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a PDF here")
                .font(.title2.weight(.semibold))
            Text("It becomes an EPUB with text that reflows, so Apple Books can set it in your font, size and theme.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("Choose PDF…") { model.choosePDF() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        }
    }

    // MARK: - Book

    private var bookDetails: some View {
        HStack(alignment: .top, spacing: 18) {
            Group {
                if let thumbnail = model.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 96, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 10) {
                LabeledField(label: "Title") {
                    TextField("Title", text: $model.title)
                }
                LabeledField(label: "Author") {
                    TextField("Author", text: $model.author)
                }
                HStack {
                    Text("\(model.inputURL?.lastPathComponent ?? "") · \(model.pageCount) pages")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Diagnostics…") { model.copyDiagnostics() }
                        .controlSize(.small)
                        .help("Copy a report on how one page reads, to help fix conversion problems")
                    Button("Choose Another…") { model.choosePDF() }
                        .controlSize(.small)
                }
            }
            .disabled(model.isConverting)
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use the first page as the cover", isOn: $includeCover)
            Toggle("Remove page numbers and running headers", isOn: $removeHeaders)
            Toggle("Use the PDF’s bookmarks for chapters", isOn: $useBookmarks)
            Toggle("Read scanned pages with text recognition", isOn: $recognizeScannedPages)
            Toggle("Keep illustration pages as pictures", isOn: $keepImagePages)
            Toggle("Open in Books when done", isOn: $openInBooksWhenDone)
        }
        .disabled(model.isConverting)
    }

    // MARK: - Progress and results

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .converting:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: model.progress)
                HStack {
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        case .finished(let result):
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved “\(result.outputURL.lastPathComponent)”")
                            .fontWeight(.medium)
                        Text(summary(result))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                HStack {
                    Button("Open in Books") { model.openInBooks(result.outputURL) }
                    Button("Show in Finder") { model.revealInFinder(result.outputURL) }
                    Spacer()
                    convertButton(title: "Convert Again…")
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                HStack {
                    Spacer()
                    convertButton(title: "Try Again…")
                }
            }
        case .empty, .ready:
            HStack {
                Spacer()
                convertButton(title: "Convert to EPUB…")
            }
        }
    }

    private func convertButton(title: String) -> some View {
        Button(title) {
            model.convert(settings: .init(includeCover: includeCover,
                                          recognizeScannedPages: recognizeScannedPages,
                                          removeHeaders: removeHeaders,
                                          useBookmarks: useBookmarks,
                                          keepImagePages: keepImagePages,
                                          openInBooksWhenDone: openInBooksWhenDone))
        }
        .keyboardShortcut(.defaultAction)
        .controlSize(.large)
    }

    private func summary(_ result: ConversionResult) -> String {
        let words = result.wordCount.formatted()
        var parts = ["\(result.chapterTitles.count) chapter\(result.chapterTitles.count == 1 ? "" : "s")",
                     "about \(words) words"]
        if result.recognizedPageCount > 0 { parts.append("\(result.recognizedPageCount) scanned pages read") }
        if result.imagePageCount > 0 { parts.append("\(result.imagePageCount) picture pages") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Drag and drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "pdf" else { return }
            Task { @MainActor in model.load(url) }
        }
        return true
    }
}

private struct LabeledField<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            content
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }
}
#endif
