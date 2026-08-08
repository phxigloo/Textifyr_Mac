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

    /// What a queued job wants from a live session.
    private enum Work {
        case translate(TranslationChunker.Split)
        /// Fetch the language assets for this pair, presenting Apple's download sheet.
        case prepareDownload
    }

    private struct PairKey: Hashable { let source: String; let target: String }
    private struct Job { let work: Work; let cont: CheckedContinuation<String, Error> }

    /// Jobs keyed by language pair. Keyed, rather than one flat list plus a single "current pair",
    /// because that older shape drained *every* queued job through whichever session reconfigured
    /// last — two overlapping requests for different pairs and both came back in one language.
    /// (Pulled forward from 26.5: adding a second job kind to a shared queue would compound it.)
    private var queues: [PairKey: [Job]] = [:]
    private var currentPair: PairKey?

    /// Whether `TranslationHostView` is on screen. Downloads need it; translation of an installed
    /// pair no longer does (26.5).
    private(set) var isHostMounted = false

    fileprivate func setHostMounted(_ mounted: Bool) { isHostMounted = mounted }

    /// Translate `text` to `targetCode` (BCP-47). `sourceCode` empty = resolve it locally.
    ///
    /// **Resolution happens here** (26.2) because this is the one place a
    /// `TranslationSession.Configuration` is built — every path, including the direct callers that
    /// skip `SessionTextTranslator`, funnels through it. A `source: nil` configuration is what makes
    /// downloads fail preflight and pop Apple's bare "select a language to translate from" sheet, so
    /// there must be no way to construct one by accident.
    func translate(_ text: String, sourceCode: String, targetCode: String) async throws -> String {
        // Normalize the target too: a caller may hand us a system-derived `en-US` while the framework
        // reported plain `en`, and the pair has to be expressed the way the framework named it.
        let target = TranslationCatalog.shared.normalized(targetCode)
        let resolved = await resolveSource(explicitCode: sourceCode, text: text, targetCode: target)

        // Identity pair: nothing to translate, and the framework errors if asked. Returning the input
        // unchanged is what a user running "translate to Turkish" over Turkish text expects.
        if SourceLanguageResolver.isSameLanguage(resolved, target) { return text }

        // Long documents go as a batch of paragraph-sized requests rather than one huge one, with the
        // separators preserved so the layout survives.
        let split = TranslationChunker.split(text)

        // **Headless path (26.5).** When the pair is already on the Mac we can build a session
        // directly — no hidden host view, so translation no longer depends on a document window
        // being open. Only asset downloads need the view-hosted session.
        if await TranslationCatalog.shared.status(from: resolved, to: target) == .installed {
            print("🌐 [translate] \(resolved)→\(target) via installed session, "
                  + "\(split.pieces.count) piece(s) — no window needed")
            let session = TranslationSession(
                installedSource: Locale.Language(identifier: resolved),
                target: Locale.Language(identifier: target))
            do {
                return try await Self.perform(split, through: session)
            } catch {
                throw TranslationFailure(underlying: error, source: resolved, target: target)
            }
        }

        // Not installed yet: only the hosted session may fetch assets, so it has to run there — and it
        // must exist. Without a mounted host this job would wait forever for a session that never
        // arrives (the same hang shape guarded on `prepareDownload`, reached here instead whenever a
        // workflow runs a not-installed pair with no window open).
        guard isHostMounted else {
            throw TranslationFailure(underlying: TranslationError.notInstalled,
                                     source: resolved, target: target)
        }

        print("🌐 [translate] \(resolved)→\(target) via hosted session (assets may need downloading)")
        return try await enqueue(.translate(split), pair: PairKey(source: resolved, target: target))
    }

    /// Translates every non-blank piece in one batch and rebuilds the document around it.
    ///
    /// Responses are matched back by `clientIdentifier` rather than by position — `translations(from:)`
    /// makes no documented ordering guarantee, and silently reordering a user's paragraphs would be a
    /// nasty way to find that out.
    private static func perform(_ split: TranslationChunker.Split,
                                through session: TranslationSession) async throws -> String {
        let indices = split.pieces.indices.filter {
            !split.pieces[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !indices.isEmpty else { return split.original }

        let requests = indices.map {
            TranslationSession.Request(sourceText: split.pieces[$0], clientIdentifier: String($0))
        }
        let responses = try await session.translations(from: requests)

        var translated = split.pieces
        for response in responses {
            guard let identifier = response.clientIdentifier, let index = Int(identifier),
                  translated.indices.contains(index) else { continue }
            translated[index] = response.targetText
        }
        return split.reassembled(with: translated)
    }

    /// Downloads the assets for an already-resolved language pair (26.4).
    ///
    /// Asks the framework to `prepareTranslation()`, which presents Apple's download sheet **with
    /// both languages already known** — so its "The language could not automatically be detected"
    /// fallback never fires, and there's one sheet instead of two. This replaces 26.1's workaround of
    /// priming a dummy translation, which passed no source and therefore could not pass preflight.
    func prepareDownload(sourceCode: String, targetCode: String) async throws {
        let catalog = TranslationCatalog.shared
        let source = catalog.normalized(sourceCode)
        let target = catalog.normalized(targetCode)

        guard !source.isEmpty, !target.isEmpty else { throw TranslationDownloadError.unresolvedPair }
        // Nothing to fetch for an identity pair, and asking would error.
        guard !SourceLanguageResolver.isSameLanguage(source, target) else { return }

        // Fail fast rather than hang. Only a view-hosted session may fetch assets, so with no host
        // mounted this job would sit in the queue forever waiting for a session that never arrives —
        // the gap flagged at the end of 26.5, now reachable from the 26.6 preflight.
        guard isHostMounted else { throw TranslationDownloadError.cannotRequestDownloads }

        _ = try await enqueue(.prepareDownload, pair: PairKey(source: source, target: target))
    }

    /// Resolves against the live catalog so unsupported guesses are rejected, and logs the outcome —
    /// the detected language is worth seeing when reading a run trace.
    private func resolveSource(explicitCode: String, text: String, targetCode: String) async -> String {
        let catalog = TranslationCatalog.shared
        await catalog.load()
        let supported = catalog.languages.isEmpty ? nil : Set(catalog.languages.map(\.id))

        let resolution = SourceLanguageResolver().resolve(
            explicitCode: explicitCode,
            text: text,
            targetCode: targetCode,
            systemCode: catalog.systemLanguageCode,
            supportedCodes: supported)

        switch resolution {
        case .resolved(let source):
            if source.origin != .explicit {
                let confidence = source.confidence.map { " (confidence \(String(format: "%.2f", $0)))" } ?? ""
                print("🌐 [translate] source resolved to \(source.code) via \(source.origin)\(confidence)")
            }
            return catalog.normalized(source.code)
        case .ambiguous(let candidates):
            // No interactive prompt on this path — a workflow may be running unattended. Take the best
            // available guess so the run proceeds; the UI asks up front where it can (26.2 picker),
            // and 26.6 adds an authoring-time preflight that settles it before a batch starts.
            let fallback = candidates.first?.code ?? catalog.systemLanguageCode
            print("🌐 [translate] source ambiguous; falling back to \(fallback)")
            return catalog.normalized(fallback)
        }
    }

    private func enqueue(_ work: Work, pair: PairKey) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queues[pair, default: []].append(Job(work: work, cont: cont))

            if currentPair == pair {
                config?.invalidate()      // same pair → re-run the task to pick up this batch
            } else if currentPair == nil {
                activate(pair)
            }
            // Otherwise another pair holds the session; `run` hands it over when that batch finishes.
        }
    }

    /// Points the host view's `.translationTask` at a specific pair. The only place a
    /// `Configuration` is constructed, and both codes are always concrete by now.
    private func activate(_ pair: PairKey) {
        currentPair = pair
        var next = TranslationSession.Configuration(
            source: Locale.Language(identifier: pair.source),
            target: Locale.Language(identifier: pair.target))

        // `Configuration` is `Equatable` and `.translationTask` only re-runs when the value actually
        // changes — so assigning one equal to the config still sitting in `config` from a previous
        // batch would strand this batch in the queue forever (no session, no completion, no error).
        // `invalidate()` bumps its version to force a fresh session. This bites whenever the same
        // pair is used twice with a drain in between: download-then-translate, or simply running the
        // same instruction a second time.
        if next == config { next.invalidate() }
        config = next
    }

    /// Called by `TranslationHostView`'s `.translationTask` action with a live session.
    fileprivate func run(_ session: TranslationSession) async {
        guard let pair = currentPair else { return }
        let batch = queues.removeValue(forKey: pair) ?? []

        for job in batch {
            do {
                switch job.work {
                case .translate(let split):
                    job.cont.resume(returning: try await Self.perform(split, through: session))

                case .prepareDownload:
                    // Only a view-hosted session may fetch assets; a directly-constructed one can't.
                    guard session.canRequestDownloads else {
                        throw TranslationDownloadError.cannotRequestDownloads
                    }
                    try await session.prepareTranslation()
                    job.cont.resume(returning: "")
                }
            } catch {
                let ns = error as NSError
                print("⚠️ [translate] \(pair.source)→\(pair.target) failed: \(error) "
                      + "· domain=\(ns.domain) code=\(ns.code)")
                // Wrap so every downstream surface — workflow alerts, the Lab's error line, the
                // engine's per-source skip prompt — reads a real explanation instead of
                // "The operation was cancelled." (NSCocoaErrorDomain 3072), which is what the
                // original bug report was full of.
                job.cont.resume(throwing: TranslationFailure(
                    underlying: error, source: pair.source, target: pair.target))
            }
        }

        // Release the session, then hand it to whichever pair is waiting.
        currentPair = nil
        if let next = queues.first(where: { !$0.value.isEmpty })?.key { activate(next) }
    }
}

/// Turns a raw `Translation` framework error into something a user can act on (26.5).
///
/// The framework's own messages are frequently useless — dismissing a sheet surfaces
/// `NSCocoaErrorDomain 3072 "The operation was cancelled."`, and a preflight failure surfaces
/// `TranslationErrorDomain Code=20 "(null)"`. Both appeared verbatim in the original bug report.
/// Wrapping at the coordinator means every caller benefits without knowing about `Translation`.
struct TranslationFailure: LocalizedError {
    let underlying: Error
    let source: String
    let target: String

    private var sourceName: String { TranslationCatalog.displayName(for: source) }
    private var targetName: String { TranslationCatalog.displayName(for: target) }

    var errorDescription: String? {
        switch underlying {
        case TranslationError.unsupportedLanguagePairing:
            return "Textifyr can't translate \(sourceName) to \(targetName) on this Mac."
        case TranslationError.unsupportedSourceLanguage:
            return "\(sourceName) isn't a language this Mac can translate from."
        case TranslationError.unsupportedTargetLanguage:
            return "\(targetName) isn't a language this Mac can translate to."
        case TranslationError.notInstalled:
            return "The \(sourceName) → \(targetName) language pack isn't on this Mac yet."
        case TranslationError.unableToIdentifyLanguage:
            return "Couldn't tell what language the text is written in."
        case TranslationError.nothingToTranslate:
            return "There was no text to translate."
        default:
            if isCancelled { return "Translation was cancelled." }
            return "Translation from \(sourceName) to \(targetName) failed."
        }
    }

    var recoverySuggestion: String? {
        switch underlying {
        case TranslationError.unsupportedLanguagePairing:
            return "Try translating to a different language, or in two steps via English."
        case TranslationError.notInstalled:
            return "Open the Translate instruction and use the Download button."
        case TranslationError.unableToIdentifyLanguage:
            return "Set \"Translate from\" explicitly instead of leaving it on Auto-detect."
        default:
            return isCancelled ? nil : underlying.localizedDescription
        }
    }

    /// True when this Mac can't translate this pair at all — the only case where offering the AI
    /// route is honest, since downloading won't help.
    var isUnsupportedPair: Bool {
        switch underlying {
        case TranslationError.unsupportedLanguagePairing,
             TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage:
            return true
        default:
            return false
        }
    }

    /// True when the user dismissed the system sheet rather than anything going wrong.
    var isCancelled: Bool {
        if underlying is CancellationError { return true }
        let ns = underlying as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError
    }
}

/// Failures specific to fetching language assets, as opposed to translating.
enum TranslationDownloadError: LocalizedError {
    /// The live session can't request downloads (not vended by a view).
    case cannotRequestDownloads
    /// One or both ends of the pair were empty — a bug, not a user-facing condition.
    case unresolvedPair

    var errorDescription: String? {
        switch self {
        case .cannotRequestDownloads:
            return "Textifyr can't start a language download right now. Keep the main window open and try again."
        case .unresolvedPair:
            return "Both languages must be known before a download can start."
        }
    }
}

/// Sendable adapter so the Services-layer `TranslationRegistry` can hold a translator that hops to
/// the main-actor coordinator. Source resolution and the identity-pair short-circuit live in the
/// coordinator, so every caller gets them — including the ones that bypass this type.
struct SessionTextTranslator: TextTranslator {
    func translate(_ text: String, sourceCode: String, targetCode: String) async throws -> String {
        try await TranslationCoordinator.shared.translate(text, sourceCode: sourceCode, targetCode: targetCode)
    }

    func availability(sourceCode: String, targetCode: String) async -> TranslationPairAvailability {
        let catalog = TranslationCatalog.shared
        await catalog.load()
        switch await catalog.status(from: sourceCode, to: targetCode) {
        case .installed:   return .installed
        case .supported:   return .needsDownload
        case .unsupported: return .unsupported
        @unknown default:  return .unknown
        }
    }

    func supportedLanguageCodes() async -> Set<String> {
        await Self.loadSupportedCodes()
    }

    @MainActor
    private static func loadSupportedCodes() async -> Set<String> {
        let catalog = TranslationCatalog.shared
        await catalog.load()
        return Set(catalog.languages.map(\.id))
    }

    func prepareDownload(sourceCode: String, targetCode: String) async throws {
        try await TranslationCoordinator.shared.prepareDownload(sourceCode: sourceCode, targetCode: targetCode)
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
                // Downloads need this view alive to vend a session that may fetch assets.
                coord.setHostMounted(true)
            }
            .onDisappear { coord.setHostMounted(false) }
    }
}

// MARK: - Config editor (used by the Action step row and the Instruction Lab)

struct TranslateConfigEditor: View {
    @Binding var config: TranslateConfig
    /// The text this instruction will actually run against, when the caller has it (the Instruction
    /// Lab does; a bare action-step row doesn't). Used to detect the source language so the
    /// availability line describes the pair that will really run.
    var sampleText: String = ""

    @ObservedObject private var catalog = TranslationCatalog.shared

    /// Sentinel tag for the "my language" target row, which maps to a Bool rather than a code.
    private static let systemTargetTag = "\u{1}system"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Translate the text to another language on your Mac — no AI, no content filter. A language may need a one-time download.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Stacked rather than one row: this pane is narrow and language names get long
            // ("Chinese, Traditional"), which squeezed the labels into wrapping mid-word.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Translate from")
                        .font(.caption).foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                        .fixedSize()
                    Picker("", selection: $config.sourceLanguageCode) {
                        Text("Auto-detect").tag("")
                        Divider()
                        ForEach(catalog.languages) { lang in Text(lang.name).tag(lang.id) }
                        unrecognizedRow(config.sourceLanguageCode)
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .disabled(!catalog.isLoaded)
                }

                // Directly under "Translate from", and labelled with the direction: this is the
                // *source* fallback, and sitting below "to" made it read as a target setting.
                // Only meaningful while the source is auto-detected — it's the answer to "what if you
                // can't tell?", which is exactly when a batch would otherwise stall or guess wrong.
                if config.sourceLanguageCode.isEmpty {
                    GridRow {
                        Text("if unsure, from")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize()
                        Picker("", selection: $config.autoSourceFallbackCode) {
                            Text("My language (\(catalog.label(for: catalog.systemLanguageCode)))").tag("")
                            Divider()
                            ForEach(catalog.languages) { lang in Text(lang.name).tag(lang.id) }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        .controlSize(.small)
                        .disabled(!catalog.isLoaded)
                        .help("Translation always needs both languages. Textifyr normally reads the text to work out which language it's in — this is what to assume when the text is too short or mixed to tell, so a run never has to stop and ask.")
                    }
                }

                // Hard visual break between the source rows and the target row. Adjacency alone
                // wasn't enough — a row next to the others gets read as belonging to them.
                GridRow {
                    Divider()
                        .gridCellColumns(2)
                        .padding(.vertical, 2)
                }

                GridRow {
                    Text("to")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                    HStack(spacing: 6) {
                        Picker("", selection: targetSelection) {
                            Text("Choose…").tag("")
                            // "My language" first: it's the answer for "put whatever comes in into my
                            // language", and it stays right if the system language ever changes.
                            Text("My language (\(catalog.label(for: catalog.systemLanguageCode)))")
                                .tag(Self.systemTargetTag)
                            Divider()
                            ForEach(catalog.languages) { lang in Text(lang.name).tag(lang.id) }
                            if !config.targetFollowsSystemLanguage {
                                unrecognizedRow(config.targetLanguageCode)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        .disabled(!catalog.isLoaded)
                        if !catalog.isLoaded { ProgressView().controlSize(.small) }
                    }
                }
            }

            if config.hasTarget {
                TranslateAvailabilityRow(config: config,
                                         sampleText: sampleText,
                                         onPinSource: { config.sourceLanguageCode = $0 })
            }
        }
        .task { await catalog.load() }
    }

    /// Keeps a saved language selectable even when this Mac can't offer it, so opening an action on
    /// another machine doesn't silently blank the config.
    @ViewBuilder
    private func unrecognizedRow(_ code: String) -> some View {
        if !code.isEmpty, catalog.language(for: code) == nil {
            Text(TranslationCatalog.displayName(for: code)).tag(code)
        }
    }

    /// Bridges the target picker's single selection onto a code *plus* the follows-system flag.
    private var targetSelection: Binding<String> {
        Binding(
            get: { config.targetFollowsSystemLanguage ? Self.systemTargetTag : config.targetLanguageCode },
            set: { newValue in
                if newValue == Self.systemTargetTag {
                    config.targetFollowsSystemLanguage = true
                } else {
                    config.targetFollowsSystemLanguage = false
                    config.targetLanguageCode = newValue
                }
            })
    }
}

/// Shows whether the chosen language is on-device, and offers a one-time download if not.
///
/// The status describes the pair that will *actually* run: the source is resolved from the real
/// sample text via `SourceLanguageResolver` (26.2), not assumed to be the user's system language.
struct TranslateAvailabilityRow: View {
    /// The instruction being described — both ends come from here via the shared planner, so this row
    /// and the actual run can't disagree.
    let config: TranslateConfig
    /// The text the instruction will run against, when available.
    var sampleText: String = ""
    /// Called when the user answers the "which language is this?" prompt, pinning the source.
    var onPinSource: ((String) -> Void)?

    @ObservedObject private var catalog = TranslationCatalog.shared
    @State private var statusText = "Checking availability…"
    @State private var icon = "hourglass"
    @State private var color = Color.secondary
    @State private var needsDownload = false
    @State private var downloading = false
    @State private var sourceNote: String?
    @State private var ambiguousCandidates: [LanguageHypothesis] = []
    @State private var showSourcePicker = false
    /// The concrete pair the last refresh settled on — what a download is requested for.
    @State private var resolvedSource = ""
    @State private var resolvedTarget = ""
    @State private var downloadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if needsDownload && !downloading {
                    // The icon is part of the control rather than decoration beside it, so the whole
                    // affordance is clickable (26.1 — reported as confusing).
                    Button { download() } label: {
                        Label("Download \(catalog.label(for: resolvedTarget))",
                              systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Text(statusText).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(statusText).font(.caption2).foregroundStyle(.secondary)
                    if downloading { ProgressView().controlSize(.small) }
                }
                Spacer()
            }

            if !ambiguousCandidates.isEmpty {
                Button { showSourcePicker = true } label: {
                    Label("Set the language it's written in…", systemImage: "questionmark.circle")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            } else if let sourceNote {
                Text(sourceNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let downloadError {
                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Secondary, deliberately: the in-app download is the primary path (it knows which
            // language this instruction needs), but System Settings is the only place to browse in
            // bulk or *remove* a language, which the framework can't do.
            if needsDownload || showsSettingsEscape {
                Button { openLanguageSettings() } label: {
                    Text("Manage languages in System Settings…").font(.caption2)
                }
                .buttonStyle(.link)
            }
        }
        .task(id: refreshKey) { await refresh() }
        .sheet(isPresented: $showSourcePicker) {
            SourceLanguagePickerSheet(
                candidates: ambiguousCandidates,
                targetCode: resolvedTarget,
                onPick: { code in
                    showSourcePicker = false
                    onPinSource?(code)
                },
                onCancel: { showSourcePicker = false })
        }
    }

    /// Also offer System Settings when a download failed or the pair is unsupported — those are the
    /// cases where the user may want to go look at what's actually installed.
    private var showsSettingsEscape: Bool { downloadError != nil || color == .red }

    /// Re-checks when the instruction changes, when the sample text changes enough to alter detection,
    /// or when the catalog drops cached availability (e.g. the user just downloaded a language in
    /// System Settings and switched back).
    private var refreshKey: String {
        "\(config.sourceLanguageCode)→\(config.targetLanguageCode)"
        + "|\(config.targetFollowsSystemLanguage)|\(config.autoSourceFallbackCode)"
        + "#\(catalog.refreshToken)#\(sampleText.count)"
    }

    private func refresh() async {
        await catalog.load()

        let supported = catalog.languages.isEmpty ? nil : Set(catalog.languages.map(\.id))
        let plan = SourceLanguageResolver().plan(
            config: config,
            text: sampleText,
            systemCode: catalog.systemLanguageCode,
            supportedCodes: supported)

        resolvedSource = plan.sourceCode
        resolvedTarget = plan.targetCode
        let name = catalog.label(for: plan.targetCode)

        if plan.sourceIsUncertain {
            // Can't answer it ourselves. Say so plainly and offer our own picker, instead of letting
            // the framework fail preflight and pop Apple's bare source-language sheet later.
            ambiguousCandidates = plan.candidates
            sourceNote = nil
            statusText = "Textifyr can't tell what language this text is in"
            icon = "questionmark.circle"; color = .orange; needsDownload = false
            return
        }

        ambiguousCandidates = []
        sourceNote = note(for: plan)

        // Same language both ends — a no-op rather than an error, and worth saying so plainly here so
        // nobody wonders why "translate" changed nothing.
        if plan.isNoOp {
            statusText = "Already in \(name) — nothing to translate"
            icon = "equal.circle"; color = .secondary; needsDownload = false
            return
        }

        switch await catalog.status(from: plan.sourceCode, to: plan.targetCode) {
        case .installed:
            statusText = "On this Mac"; icon = "checkmark.circle.fill"; color = .green; needsDownload = false
        case .supported:
            statusText = "\(name) isn't on this Mac yet · one-time download"
            icon = "arrow.down.circle"; color = .orange; needsDownload = true
        case .unsupported:
            // Name both ends: the framework supports languages but not every *pair*, and "Japanese
            // can't be translated" is misleading when the real problem is Turkish → Japanese.
            statusText = "\(catalog.label(for: plan.sourceCode)) → \(name) isn't supported on this Mac"
            icon = "xmark.octagon.fill"; color = .red; needsDownload = false
        @unknown default:
            statusText = "Availability unknown"; icon = "questionmark.circle"; color = .secondary; needsDownload = false
        }
    }

    /// How the source was arrived at, so the user can see (and correct) what we assumed.
    private func note(for plan: TranslatePlan) -> String? {
        let name = catalog.label(for: plan.sourceCode)
        switch plan.sourceOrigin {
        case .explicit:
            return nil   // the "Translate from" picker already says it
        case .detected:
            return "Detected as \(name)"
        case .systemLanguage:
            return "Assuming the text is in \(name)"
        }
    }

    private func download() {
        downloading = true
        downloadError = nil
        Task { @MainActor in
            do {
                try await TranslationCoordinator.shared.prepareDownload(
                    sourceCode: resolvedSource, targetCode: resolvedTarget)
            } catch let failure as TranslationFailure {
                // Dismissing Apple's sheet is a cancellation, not a failure — say nothing.
                if !failure.isCancelled { downloadError = failure.localizedDescription }
            } catch {
                downloadError = error.localizedDescription
            }
            catalog.invalidateAvailability()   // the asset set may have changed; drop stale statuses
            await refresh()
            downloading = false
        }
    }

    /// Language & Region, where languages can be browsed in bulk and — unlike in-app — *removed*.
    private func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
