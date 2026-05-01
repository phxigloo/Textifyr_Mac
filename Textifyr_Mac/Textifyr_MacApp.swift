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
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task { await prefetchDiarizationModels() }
        }
        .windowStyle(.hiddenTitleBar)
        .modelContainer(container)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Document") {
                    NotificationCenter.default.post(name: .newDocument, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

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
