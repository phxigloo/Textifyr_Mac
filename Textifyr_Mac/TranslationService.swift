import SwiftUI
import Combine
import Translation
import TextifyrModels
import TextifyrServices

// MARK: - Coordinator: bridges the view-vended TranslationSession to a plain async API

/// Apple's `TranslationSession` is only vended inside a SwiftUI `.translationTask` closure, so the
/// headless pipeline engine can't call it directly. This coordinator queues translation requests
/// and nudges a hidden host view's configuration; when the host's task runs with a live session,
/// it drains the queue and resumes each caller's continuation. Result: a normal `async translate`.
@MainActor
final class TranslationCoordinator: ObservableObject {
    static let shared = TranslationCoordinator()

    @Published fileprivate var config: TranslationSession.Configuration?

    private struct Job { let text: String; let cont: CheckedContinuation<String, Error> }
    private var queue: [Job] = []
    private var currentTarget = ""
    private var currentSource = ""

    /// Translate `text` to `targetCode` (BCP-47). `sourceCode` empty = auto-detect.
    func translate(_ text: String, sourceCode: String, targetCode: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.append(Job(text: text, cont: cont))
            if config != nil, currentTarget == targetCode, currentSource == sourceCode {
                config?.invalidate()   // same language pair → re-run the task for this batch
            } else {
                currentTarget = targetCode
                currentSource = sourceCode
                let target = Locale.Language(identifier: targetCode)
                let source = sourceCode.isEmpty ? nil : Locale.Language(identifier: sourceCode)
                config = TranslationSession.Configuration(source: source, target: target)
            }
        }
    }

    /// Called by `TranslationHostView`'s `.translationTask` action with a live session.
    fileprivate func run(_ session: TranslationSession) async {
        let batch = queue
        queue.removeAll()
        guard !batch.isEmpty else { return }
        do {
            try await session.prepareTranslation()   // downloads the language model if needed
        } catch {
            batch.forEach { $0.cont.resume(throwing: error) }
            return
        }
        for job in batch {
            do {
                let response = try await session.translate(job.text)
                job.cont.resume(returning: response.targetText)
            } catch {
                job.cont.resume(throwing: error)
            }
        }
    }
}

/// Sendable adapter so the Services-layer `TranslationRegistry` can hold a translator that hops to
/// the main-actor coordinator.
struct SessionTextTranslator: TextTranslator {
    func translate(_ text: String, sourceCode: String, targetCode: String) async throws -> String {
        try await TranslationCoordinator.shared.translate(text, sourceCode: sourceCode, targetCode: targetCode)
    }
}

// MARK: - Hidden host: keeps a live TranslationSession available while the app window is open

struct TranslationHostView: View {
    @ObservedObject private var coord = TranslationCoordinator.shared
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(coord.config) { session in
                await coord.run(session)
            }
            .onAppear {
                if TranslationRegistry.current == nil {
                    TranslationRegistry.current = SessionTextTranslator()
                }
            }
    }
}

// MARK: - Availability

enum TranslationAvailability {
    /// Whether `targetCode` is installed / downloadable / unsupported, from the user's language.
    static func status(targetCode: String) async -> LanguageAvailability.Status {
        let target = Locale.Language(identifier: targetCode)
        return await LanguageAvailability().status(from: Locale.current.language, to: target)
    }
}

// MARK: - Config editor (used by the Action step row and the Instruction Lab)

struct TranslateConfigEditor: View {
    @Binding var config: TranslateConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Translate the text to another language on your Mac — no AI, no content filter. A language may need a one-time download.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Translate to").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $config.targetLanguageCode) {
                    Text("Choose…").tag("")
                    ForEach(translationLanguages) { lang in Text(lang.name).tag(lang.id) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Spacer()
            }

            if !config.targetLanguageCode.isEmpty {
                TranslateAvailabilityRow(targetCode: config.targetLanguageCode)
            }
        }
    }
}

/// Shows whether the chosen language is on-device, and offers a one-time download if not.
struct TranslateAvailabilityRow: View {
    let targetCode: String
    @State private var statusText = "Checking availability…"
    @State private var icon = "hourglass"
    @State private var color = Color.secondary
    @State private var needsDownload = false
    @State private var downloading = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(statusText).font(.caption2).foregroundStyle(.secondary)
            if needsDownload {
                if downloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Download") { download() }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
            Spacer()
        }
        .task(id: targetCode) { await refresh() }
    }

    private func refresh() async {
        switch await TranslationAvailability.status(targetCode: targetCode) {
        case .installed:
            statusText = "Installed on this device"; icon = "checkmark.circle.fill"; color = .green; needsDownload = false
        case .supported:
            statusText = "Available — needs a one-time download"; icon = "arrow.down.circle"; color = .orange; needsDownload = true
        case .unsupported:
            statusText = "Not available on this device"; icon = "xmark.octagon.fill"; color = .red; needsDownload = false
        @unknown default:
            statusText = "Availability unknown"; icon = "questionmark.circle"; color = .secondary; needsDownload = false
        }
    }

    private func download() {
        downloading = true
        Task { @MainActor in
            // Priming a translation triggers prepareTranslation(), which presents the system download.
            _ = try? await TranslationCoordinator.shared.translate("hello", sourceCode: "", targetCode: targetCode)
            await refresh()
            downloading = false
        }
    }
}
