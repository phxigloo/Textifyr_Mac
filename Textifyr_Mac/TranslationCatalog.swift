import SwiftUI
import Combine
import Translation
import TextifyrModels

/// The single source of truth for "which languages can this Mac translate, and which are on device".
///
/// Replaces the old hand-written `translationLanguages` array (Phase 26.1). That list was wrong in
/// two ways: it omitted languages the framework does support (notably **English**, so the user's own
/// locale could never be a target), and its `isSupported` flag was a hand-maintained guess about
/// *Apple Intelligence writing-tools* coverage — a different subsystem from the *Translation*
/// framework that actually runs. Here the list comes from `LanguageAvailability.supportedLanguages`
/// and per-pair availability comes from `LanguageAvailability.status(from:to:)`, so both are facts.
@MainActor
final class TranslationCatalog: ObservableObject {
    static let shared = TranslationCatalog()

    /// One translatable language, keyed by the identifier the framework itself reported so codes
    /// round-trip exactly back into `TranslationSession.Configuration`.
    struct Language: Identifiable, Hashable {
        /// BCP-47 identifier as reported by `LanguageAvailability` (e.g. "en", "zh-Hans").
        let id: String
        /// Localized display name (e.g. "Chinese, Simplified" in an English UI).
        let name: String
    }

    @Published private(set) var languages: [Language] = []
    @Published private(set) var isLoaded = false
    /// Bumped whenever cached availability is dropped, so views can re-run `.task(id:)`.
    @Published private(set) var refreshToken = 0

    private struct Pair: Hashable { let source: String; let target: String }
    private var statusCache: [Pair: LanguageAvailability.Status] = [:]
    private var loadTask: Task<Void, Never>?
    private var activeObserver: (any NSObjectProtocol)?

    private init() {
        // A language downloaded in System Settings while we were in the background is now installed,
        // but our cached statuses still say otherwise. Drop them on reactivation so the UI corrects
        // itself deliberately rather than by luck.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TranslationCatalog.shared.invalidateAvailability() }
        }
    }

    // MARK: - Loading

    /// Loads the supported-language list once. Safe to call from every `.task` that needs the list.
    func load() async {
        if isLoaded { return }
        if let loadTask { await loadTask.value; return }
        let task = Task { @MainActor in
            let supported = await LanguageAvailability().supportedLanguages
            languages = Self.buildLanguages(from: supported)
            isLoaded = true
            // Logged because "why isn't language X in the list?" is a recurring question, and the
            // answer is always this list: it's everything the *Translation* framework supports here,
            // which is a smaller catalog than System Settings' downloadable system languages.
            print("🌐 [translate] \(languages.count) translatable languages: "
                  + languages.map(\.id).joined(separator: ", "))
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// Drops cached availability (not the language list — the supported *set* doesn't change at
    /// runtime, only which of them are installed).
    func invalidateAvailability() {
        guard !statusCache.isEmpty else { return }
        statusCache.removeAll()
        refreshToken += 1
    }

    private static func buildLanguages(from supported: [Locale.Language]) -> [Language] {
        var seen = Set<String>()
        var codes: [String] = []
        for language in supported {
            let code = identifier(for: language)
            guard !code.isEmpty, seen.insert(code).inserted else { continue }
            codes.append(code)
        }

        // A region only belongs in the label when it distinguishes siblings. The framework reports
        // Arabic as `ar-AE`, and "Arabic (United Arab Emirates)" reads like a mistake when it's the
        // only Arabic on offer — whereas "English (United Kingdom)" beside "English" is genuinely
        // informative. So: count languages per base subtag and drop the region where it's unique.
        var countsBySubtag: [String: Int] = [:]
        for code in codes {
            let subtag = Locale.Language(identifier: code).languageCode?.identifier ?? code
            countsBySubtag[subtag, default: 0] += 1
        }

        let result = codes.map { code -> Language in
            let subtag = Locale.Language(identifier: code).languageCode?.identifier ?? code
            let isOnlyVariant = countsBySubtag[subtag] == 1
            let name = isOnlyVariant ? baseDisplayName(for: code) : displayName(for: code)
            return Language(id: code, name: name)
        }
        return result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Language name without region, keeping any script ("Chinese, Simplified" stays distinct from
    /// "Chinese, Traditional"; "Arabic (United Arab Emirates)" collapses to "Arabic").
    ///
    /// The script is read from the code string itself rather than `Locale.Language.script`, which
    /// *infers* one — for "tr" it reports `Latn`, and reattaching that yields "Turkish (Latin)".
    nonisolated private static func baseDisplayName(for code: String) -> String {
        let parts = code.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").map(String.init)
        guard let subtag = parts.first?.lowercased(), !subtag.isEmpty else { return displayName(for: code) }
        // A script subtag is exactly four letters ("Hans"); a region is two letters or three digits.
        let script = parts.dropFirst().first { $0.count == 4 && $0.allSatisfy(\.isLetter) }
        let withoutRegion = script.map { "\(subtag)-\($0)" } ?? subtag
        let name = Locale.current.localizedString(forIdentifier: withoutRegion) ?? ""
        return name.isEmpty ? displayName(for: code) : name
    }

    /// Prefer the shortest identifier that still carries the distinguishing script/region, so we get
    /// "en" rather than "en_Latn_US" but keep "zh-Hans" distinct from "zh-Hant".
    private static func identifier(for language: Locale.Language) -> String {
        let minimal = language.minimalIdentifier
        if !minimal.isEmpty { return minimal }
        return language.languageCode?.identifier ?? ""
    }

    // MARK: - Display names

    /// Localized name for a language code. Static, state-free and `nonisolated` so the many sync
    /// label sites — including non-main-actor ones like `TranslationFailure`'s messages — can use it
    /// without a loaded catalog or an actor hop.
    nonisolated static func displayName(for code: String) -> String {
        guard !code.isEmpty else { return "" }
        if let name = Locale.current.localizedString(forIdentifier: code), !name.isEmpty {
            return name
        }
        // `forIdentifier:` wants an underscore-style identifier for some region forms.
        let normalized = code.replacingOccurrences(of: "-", with: "_")
        if let name = Locale.current.localizedString(forIdentifier: normalized), !name.isEmpty {
            return name
        }
        return code
    }

    /// Display name preferring the catalog's own (region-trimmed) label, so a language reads the same
    /// in a picker, a status line, and a step summary. Falls back to the raw localized name.
    func label(for code: String) -> String {
        language(for: code)?.name ?? Self.displayName(for: code)
    }

    /// One-line description of a translate instruction, for step rows and library summaries.
    /// Understands "into my language", which a bare target-code lookup would report as "(none)".
    func summary(for config: TranslateConfig) -> String {
        if config.targetFollowsSystemLanguage {
            return "Translate into my language (\(label(for: systemLanguageCode)))"
        }
        guard !config.targetLanguageCode.isEmpty else { return "Translate (no language chosen)" }
        let to = label(for: config.targetLanguageCode)
        guard !config.sourceLanguageCode.isEmpty else { return "Translate to \(to)" }
        return "Translate \(label(for: config.sourceLanguageCode)) → \(to)"
    }

    /// The catalog's own identifier for `code`, or `code` unchanged when it isn't in the catalog.
    /// Used to normalize a stored/system code (e.g. `en-US`) onto what the framework reported (`en`).
    func normalized(_ code: String) -> String {
        language(for: code)?.id ?? code
    }

    // MARK: - Lookup + normalization

    /// Finds the catalog entry for `code`, tolerating identifier mismatches.
    ///
    /// This is the fix for the reported "my own locale isn't in the Translate To list": the system
    /// language is often `en-US` while the framework reports plain `en`, so an exact-match lookup
    /// misses and the user's language appears unavailable. Falls back to matching the language
    /// subtag (preferring an entry whose script also matches).
    func language(for code: String) -> Language? {
        guard !code.isEmpty else { return nil }
        if let exact = languages.first(where: { $0.id.caseInsensitiveCompare(code) == .orderedSame }) {
            return exact
        }
        let wanted = Locale.Language(identifier: code)
        guard let subtag = wanted.languageCode?.identifier else { return nil }
        let sameSubtag = languages.filter {
            Locale.Language(identifier: $0.id).languageCode?.identifier == subtag
        }
        if let script = wanted.script?.identifier,
           let scriptMatch = sameSubtag.first(where: {
               Locale.Language(identifier: $0.id).script?.identifier == script
           }) {
            return scriptMatch
        }
        // Prefer the plainest entry ("en" over "en-GB") when the caller gave no script.
        return sameSubtag.min { $0.id.count < $1.id.count }
    }

    /// The catalog entry matching the user's system language, if it's translatable at all.
    var systemLanguage: Language? {
        language(for: identifierForSystemLanguage)
    }

    /// The user's system language code, normalized to a catalog entry when one exists.
    var systemLanguageCode: String {
        systemLanguage?.id ?? identifierForSystemLanguage
    }

    private var identifierForSystemLanguage: String {
        Self.identifier(for: Locale.current.language)
    }

    /// Whether two codes name the same language, ignoring region ("en" vs "en-GB").
    ///
    /// Needed because `status(from:to:)` reports an identity pair as `.unsupported` — accurate
    /// (translating English to English isn't a thing) but disastrous to render literally, since the
    /// user's own language is the most common target of all.
    func isSameLanguage(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.caseInsensitiveCompare(b) == .orderedSame { return true }
        let lhs = Locale.Language(identifier: a).languageCode?.identifier
        let rhs = Locale.Language(identifier: b).languageCode?.identifier
        guard let lhs, let rhs else { return false }
        return lhs == rhs
    }

    // MARK: - Availability

    /// Cached `LanguageAvailability` status for a specific pair. Unlike the old
    /// `TranslationAvailability.status`, the source is a parameter — status for the pair that will
    /// actually run, not always "from the user's locale".
    func status(from sourceCode: String, to targetCode: String) async -> LanguageAvailability.Status {
        guard !targetCode.isEmpty else { return .unsupported }
        let source = sourceCode.isEmpty ? systemLanguageCode : sourceCode
        let pair = Pair(source: source, target: targetCode)
        if let cached = statusCache[pair] { return cached }
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: targetCode)
        )
        statusCache[pair] = status
        return status
    }

    /// Which of the supported languages are already downloaded, translating *from* `sourceCode`.
    ///
    /// Checked concurrently and written to the cache in one pass. Doing this one-at-a-time through
    /// `status(from:to:)` would serialize every check on the main actor — noticeably sluggish the
    /// first time a language list opens.
    func installedTargets(from sourceCode: String) async -> Set<String> {
        let source = sourceCode.isEmpty ? systemLanguageCode : sourceCode
        let codes = languages.map(\.id)
        let uncached = codes.filter { statusCache[Pair(source: source, target: $0)] == nil }

        if !uncached.isEmpty {
            let results = await withTaskGroup(
                of: (String, LanguageAvailability.Status).self
            ) { group -> [(String, LanguageAvailability.Status)] in
                for code in uncached {
                    group.addTask {
                        let status = await LanguageAvailability().status(
                            from: Locale.Language(identifier: source),
                            to: Locale.Language(identifier: code)
                        )
                        return (code, status)
                    }
                }
                var collected: [(String, LanguageAvailability.Status)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (code, status) in results {
                statusCache[Pair(source: source, target: code)] = status
            }
        }

        return Set(codes.filter { statusCache[Pair(source: source, target: $0)] == .installed })
    }
}
