import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

@main
struct Textifyr_MacApp: App {
    let container: ModelContainer
    @StateObject private var appState = AppState()

    init() {
        do {
            container = try ModelContainerFactory.makeContainer()
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        DataSeeder.seedIfNeeded(context: container.mainContext)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task { await prefetchDiarizationModels() }
        }
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
    static let newDocument             = Notification.Name("TextifyrNewDocument")
    static let openPipelineEditorSheet = Notification.Name("TextifyrOpenPipelineEditor")
    static let openPromptBuilderSheet  = Notification.Name("TextifyrOpenPromptBuilder")
}

// MARK: - Commands

private struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Textifyr") {
                openWindow(id: "about")
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Document") {
                NotificationCenter.default.post(name: .newDocument, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Sources") {
            Button("AI Writer")        { appState.pendingSourceMethod = .appleIntelligence }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Screen Capture")   { appState.pendingSourceMethod = .screenCapture }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Microphone")       { appState.pendingSourceMethod = .microphone }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Audio File")       { appState.pendingSourceMethod = .audioFile }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Video Audio")      { appState.pendingSourceMethod = .videoAudio }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Camera")           { appState.pendingSourceMethod = .camera }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Photo Library")    { appState.pendingSourceMethod = .photoLibrary }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Image (OCR)")      { appState.pendingSourceMethod = .imageFile }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Button("Text Editor")      { appState.pendingSourceMethod = .rtfEditor }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("PDF")              { appState.pendingSourceMethod = .pdf }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Web URL")          { appState.pendingSourceMethod = .webURL }
                .keyboardShortcut("w", modifiers: [.command, .option])
            Button("Embed Image")      { appState.pendingSourceMethod = .smartVision }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }
        CommandMenu("Tools") {
            Button("Open Main Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("1", modifiers: .command)

            Divider()

            Button("Prompt Builder") {
                NotificationCenter.default.post(name: .openPromptBuilderSheet, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Action Editor") {
                NotificationCenter.default.post(name: .openPipelineEditorSheet, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Textifyr Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}
