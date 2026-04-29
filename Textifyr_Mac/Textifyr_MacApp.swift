import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

@main
struct Textifyr_MacApp: App {
    let container: ModelContainer
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    init() {
        do {
            container = try ModelContainerFactory.makeContainer()
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        DataSeeder.seedIfNeeded(context: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task { await prefetchDiarizationModels() }
        }
        .modelContainer(container)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Document") {
                    NotificationCenter.default.post(name: .newDocument, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .windowSize) {
                Button("Pipeline Editor") {
                    openWindow(id: "pipeline-editor")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Window("Pipeline Editor", id: "pipeline-editor") {
            PipelineEditorView()
        }
        .modelContainer(container)
        .defaultSize(width: 820, height: 580)

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
    static let newDocument = Notification.Name("TextifyrNewDocument")
}
