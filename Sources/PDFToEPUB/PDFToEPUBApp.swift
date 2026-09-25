#if os(macOS)
import AppKit
import SwiftUI

@main
struct PDFToEPUBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("PDF to EPUB", id: "main") {
            ContentView(model: ConverterModel.shared)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") { ConverterModel.shared.choosePDF() }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started with `swift run` rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// PDFs dropped on the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        if let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            Task { @MainActor in ConverterModel.shared.load(pdf) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#else
@main
enum PDFToEPUBApp {
    static func main() {
        print("The PDF to EPUB app needs macOS.")
    }
}
#endif
