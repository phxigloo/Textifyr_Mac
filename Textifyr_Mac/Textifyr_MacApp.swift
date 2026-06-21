import SwiftUI
import SwiftData
import AppKit
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

extension Notification.Name {
    /// Posted by the AppDelegate's Apple Event URL handler so the running app can
    /// process a `textifyr://` deep link without SwiftUI spawning a new window.
    static let incomingDeepLink = Notification.Name("TextifyrIncomingDeepLink")
    /// Posted with `[URL]` when files are dropped on the Dock icon / opened with Textifyr.
    static let filesDropped = Notification.Name("TextifyrFilesDropped")
    /// Posted to switch the focused document to its Sources tab (e.g. audio/video
    /// dropped on the Output needs to be transcribed in Sources).
    static let requestSourcesTab = Notification.Name("TextifyrRequestSourcesTab")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool { false }

    /// Install our own GetURL Apple Event handler. SwiftUI's WindowGroup otherwise
    /// responds to a `textifyr://` URL by opening a *second* Main Window. By
    /// handling the event ourselves we keep a single window: we bring the existing
    /// one forward and post the URL for the app to act on. (ContentView no longer
    /// uses onOpenURL, so this is the sole deep-link path.)
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .incomingDeepLink, object: url)
    }

    /// Files dropped on the Dock icon (or opened via "Open With → Textifyr").
    /// Hand the URLs to the running window so they go through the same drop path
    /// (including the image OCR/Embed prompt) as in-window drops.
    func application(_ application: NSApplication, open urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .filesDropped, object: fileURLs)
    }

    /// Called when the app is re-activated while already running — e.g. the user
    /// clicks the Dock icon. Bring an existing window forward rather than letting
    /// SwiftUI spawn a duplicate Main Window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(self)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

@main
struct Textifyr_MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    let container: ModelContainer
    @StateObject private var appState = AppState()

    init() {
        do {
            container = try ModelContainerFactory.makeContainer()
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        DataSeeder.seedIfNeeded(context: container.mainContext)
        Self.sweepStaleTempFiles()
    }

    /// Deletes UUID-named export temp files older than 2 hours left by a previous session.
    private static func sweepStaleTempFiles() {
        let exportExtensions: Set<String> = ["rtf", "rtfd", "pdf", "xlsx", "html", "md", "txt", "csv"]
        let cutoff = Date().addingTimeInterval(-2 * 60 * 60)
        let tempDir = FileManager.default.temporaryDirectory
        DispatchQueue.global(qos: .background).async {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles) else { return }
            for url in items {
                guard exportExtensions.contains(url.pathExtension.lowercased()) else { continue }
                // Only remove files whose name is a bare UUID (36 chars, 4 dashes) —
                // the pattern ExportService.write(data:extension:) always produces.
                let base = url.deletingPathExtension().lastPathComponent
                guard base.count == 36, base.filter({ $0 == "-" }).count == 4 else { continue }
                guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                      created < cutoff else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task { await prefetchDiarizationModels() }
        }
        // NOTE: `handlesExternalEvents` is deliberately omitted. With it set,
        // opening the `textifyr://` deep link from the Share Extension caused
        // SwiftUI to spawn a second Main Window. The existing window now receives
        // the URL via `onOpenURL`; AppDelegate.applicationShouldHandleReopen
        // brings it to the front.
        .windowStyle(.hiddenTitleBar)
        .modelContainer(container)
        .commands { AppCommands(appState: appState) }

        Window("About Textifyr", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Textifyr Help", id: "help") {
            HelpWindowView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 600)

        Settings {
            SettingsView()
        }
        .modelContainer(container)
    }
}

// Downloads SpeakerKit CoreML models silently in the background on first launch.
private func prefetchDiarizationModels() async {
    let service = DiarizationService()
    _ = await service.ensureModelsLoaded(onDownloadNeeded: {})
}

extension Notification.Name {
    // Existing
    static let newDocument             = Notification.Name("TextifyrNewDocument")
    static let openPipelineEditorSheet = Notification.Name("TextifyrOpenPipelineEditor")
    static let openPromptBuilderSheet  = Notification.Name("TextifyrOpenPromptBuilder")
    static let openWorkflowManager     = Notification.Name("TextifyrOpenWorkflowManager")
    // File menu
    static let exportDocument          = Notification.Name("TextifyrExportDocument")
    static let printDocument           = Notification.Name("TextifyrPrintDocument")
    static let openInPages             = Notification.Name("TextifyrOpenInPages")
    static let openInNumbers           = Notification.Name("TextifyrOpenInNumbers")
    // Tools menu
    static let formatDocument          = Notification.Name("TextifyrFormatDocument")
    // View menu
    static let toggleSidebar           = Notification.Name("TextifyrToggleSidebar")
    static let toggleInspector         = Notification.Name("TextifyrToggleInspector")
    // Edit menu
    static let showFindReplace         = Notification.Name("TextifyrShowFindReplace")
    // Format menu
    static let menuFormatBold          = Notification.Name("TextifyrMenuBold")
    static let menuFormatItalic        = Notification.Name("TextifyrMenuItalic")
    static let menuFormatUnderline     = Notification.Name("TextifyrMenuUnderline")
    static let menuFormatStrikethrough = Notification.Name("TextifyrMenuStrikethrough")
    static let menuFormatBigger        = Notification.Name("TextifyrMenuBigger")
    static let menuFormatSmaller       = Notification.Name("TextifyrMenuSmaller")
    static let menuFormatAlignLeft     = Notification.Name("TextifyrMenuAlignLeft")
    static let menuFormatAlignCenter   = Notification.Name("TextifyrMenuAlignCenter")
    static let menuFormatAlignRight    = Notification.Name("TextifyrMenuAlignRight")
    static let menuFormatAlignJustify  = Notification.Name("TextifyrMenuAlignJustify")
    static let menuFormatBulletList    = Notification.Name("TextifyrMenuBulletList")
    static let menuFormatNumberedList  = Notification.Name("TextifyrMenuNumberedList")
    static let menuFormatSuperscript   = Notification.Name("TextifyrMenuSuperscript")
    static let menuFormatSubscript     = Notification.Name("TextifyrMenuSubscript")
}

// MARK: - Commands

private struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let appState: AppState

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    var body: some Commands {

        // MARK: App menu
        CommandGroup(replacing: .appInfo) {
            Button("About Textifyr") { openWindow(id: "about") }
        }

        // MARK: File — New + Main Window
        CommandGroup(replacing: .newItem) {
            Button("New Document") { post(.newDocument) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Main Window") { openWindow(id: "main") }
                .keyboardShortcut("1", modifiers: .command)
        }

        // MARK: File — Export / Print / Open in…
        CommandGroup(after: .newItem) {
            Divider()
            Button("Export…") { post(.exportDocument) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appState.outputTabIsActive || !appState.activeDocumentHasOutput)
            Divider()
            Button("Open in Pages")   { post(.openInPages) }
                .disabled(!appState.outputTabIsActive || !appState.activeDocumentHasOutput)
            Button("Open in Numbers") { post(.openInNumbers) }
                .disabled(!appState.outputTabIsActive || !appState.activeDocumentHasOutput)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { post(.printDocument) }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!appState.outputTabIsActive || !appState.activeDocumentHasOutput)
        }

        // MARK: Edit — Find & Replace
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find & Replace") { post(.showFindReplace) }
                .keyboardShortcut("f", modifiers: .command)
        }

        // MARK: Format menu
        CommandMenu("Format") {
            Button("Bold")          { post(.menuFormatBold) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic")        { post(.menuFormatItalic) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Underline")     { post(.menuFormatUnderline) }
                .keyboardShortcut("u", modifiers: .command)
            Button("Strikethrough") { post(.menuFormatStrikethrough) }
            Divider()
            Button("Bigger")        { post(.menuFormatBigger) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller")       { post(.menuFormatSmaller) }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
            Button("Align Left")    { post(.menuFormatAlignLeft) }
                .keyboardShortcut("{", modifiers: .command)
            Button("Align Center")  { post(.menuFormatAlignCenter) }
                .keyboardShortcut("|", modifiers: .command)
            Button("Align Right")   { post(.menuFormatAlignRight) }
                .keyboardShortcut("}", modifiers: .command)
            Button("Justify")       { post(.menuFormatAlignJustify) }
            Divider()
            Button("Bullet List")   { post(.menuFormatBulletList) }
            Button("Numbered List") { post(.menuFormatNumberedList) }
            Divider()
            Button("Superscript")   { post(.menuFormatSuperscript) }
            Button("Subscript")     { post(.menuFormatSubscript) }
            Divider()
            Button("Fonts…")        { NSFontManager.shared.orderFrontFontPanel(nil) }
                .keyboardShortcut("t", modifiers: .command)
        }

        // MARK: Sources menu
        CommandMenu("Sources") {
            Button("AI Writer")      { appState.pendingSourceMethod = .appleIntelligence }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Screen Capture") { appState.pendingSourceMethod = .screenCapture }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Microphone")     { appState.pendingSourceMethod = .microphone }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Audio File")     { appState.pendingSourceMethod = .audioFile }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Video Audio")    { appState.pendingSourceMethod = .videoAudio }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Camera")         { appState.pendingSourceMethod = .camera }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Photo Library")  { appState.pendingSourceMethod = .photoLibrary }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Image (OCR)")    { appState.pendingSourceMethod = .imageFile }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Button("Text Editor")    { appState.pendingSourceMethod = .rtfEditor }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("PDF")            { appState.pendingSourceMethod = .pdf }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Web URL")        { appState.pendingSourceMethod = .webURL }
                .keyboardShortcut("w", modifiers: [.command, .option])
            Button("Embed Image")    { appState.pendingSourceMethod = .smartVision }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }

        // MARK: Tools menu
        CommandMenu("Tools") {
            Button("Format Document") { post(.formatDocument) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!appState.outputTabIsActive)
            Divider()
            Button("Prompt Builder") { post(.openPromptBuilderSheet) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Action Editor")  { post(.openPipelineEditorSheet) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Workflows…")     { post(.openWorkflowManager) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        // MARK: View menu
        CommandMenu("View") {
            Button("Show/Hide Sidebar")         { post(.toggleSidebar) }
            Button("Show/Hide Action Inspector") { post(.toggleInspector) }
        }

        // MARK: Help menu
        CommandGroup(replacing: .help) {
            Button("Textifyr Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
