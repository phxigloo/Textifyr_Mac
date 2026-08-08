import SwiftUI
import SwiftData
import AppKit
import Combine
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

// MARK: - Selection type

private enum SampleSelection: Hashable {
    case scratchpad
    case saved(UUID)
}


// MARK: - Main view

struct PromptBuilderView: View {
    /// Optional initial state when opened from an Action step (see `PromptBuilderSeed`).
    var seed: PromptBuilderSeed? = nil
    /// True when shown as the Instruction Lab workspace mode (fills the window, no Cancel).
    var isEmbedded: Bool = false

    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \PromptSample.sortOrder) private var allSamples: [PromptSample]
    @Query(sort: \SavedPrompt.sortOrder) private var allSavedPrompts: [SavedPrompt]

    @State private var promptText: String = ""
    @State private var sampleSelection: SampleSelection? = .scratchpad
    @State private var scratchpadText: String = ""
    @State private var scopeFilter: PipelineScope? = nil

    @State private var isRunning = false
    @State private var runTask: Task<Void, Never>? = nil
    @State private var runProgress: DocumentFormattingService.Progress? = nil
    @State private var testResult: String? = nil
    @State private var testError: String? = nil

    @State private var showImprovePanel = false
    @FocusState private var promptFocused: Bool
    @State private var chatMessages: [PromptChatMessage] = []
    @State private var chatInput: String = ""
    @State private var isChatting = false
    @State private var chatTask: Task<Void, Never>? = nil
    @State private var chatSession: (any ModelSession)? = nil
    @State private var chatNeedsContextRefresh = false

    @State private var editingName: String = ""
    @State private var editingText: String = ""
    @State private var editingScope: PipelineScope = .source

    @State private var showingLoadPromptSheet    = false   // pick from the SavedPrompt library
    @State private var showingSaveLibrarySheet   = false   // save the current prompt to the library
    @State private var showingImportActionSheet  = false   // secondary: pull a prompt out of an action step
    @State private var showingSampleManager      = false   // Text Sample Manager sheet (add/edit/delete + scope)
    @State private var showingSamplePicker       = false   // Input pane's sample-selection popover
    @State private var showingPromptPicker       = false   // Instruction pane's Saved Prompts popover
    @State private var promptScopeFilter: PipelineScope? = nil  // scope lens for the Saved Prompts popover

    /// Where the Instruction Lab was opened from — drives which chrome shows and where Save goes.
    /// `.documentSource` (a drilled-in source, `editOrigin` set) and `.action` (a step's Improve
    /// button, seed carries `actionID`) both already know the scope; only `.library` needs to pick it.
    private enum Origin { case library, action, documentSource }
    private var origin: Origin {
        if appState.editOrigin != nil { return .documentSource }
        if seed?.actionID != nil { return .action }
        return .library
    }

    // "Run up to here" context (set from a seed when improving a mid-chain step).
    @State private var rthActionID: UUID? = nil
    @State private var rthStepIndex: Int? = nil

    // Provenance of the Scratchpad text (22.0e) — set when populated by run-to-here.
    @State private var scratchpadProvenance: String? = nil
    @State private var settingScratchpadProgrammatically = false

    // The originating step's "Check the result" settings, when seeded from a step (22.0c).
    @State private var stepVerify: StepVerifyConfig? = nil

    // Kind-aware instruction editing (Stage 3): the middle pane edits one of these per `kind`.
    @State private var kind: PipelineStepKind = .aiPrompt
    @State private var transformConfig = TextTransformConfig()
    @State private var extractConfig = ExtractFieldsConfig()
    @State private var translateConfig = TranslateConfig()
    // True when a transform's input/config changed since its result was last computed, so the
    // user knows to press Test again (transforms are user-run now, not live).
    @State private var resultStale = false

    private static let draftPromptKey     = "promptBuilder.draftText"
    private static let draftScratchpadKey = "promptBuilder.scratchpadText"
    private let sampleLimit = AppConstants.maxPromptSamples

    private var filteredSamples: [PromptSample] {
        guard let f = scopeFilter else { return allSamples }
        return allSamples.filter { $0.scope == f }
    }

    private var selectedSample: PromptSample? {
        guard case .saved(let id) = sampleSelection else { return nil }
        return allSamples.first { $0.id == id }
    }

    private var sampleIsDirty: Bool {
        guard let sample = selectedSample else { return false }
        return editingName != sample.name || editingText != sample.sampleText || editingScope != sample.scope
    }

    private var activeText: String {
        switch sampleSelection {
        case .scratchpad: return scratchpadText
        case .saved:      return editingText
        case nil:         return ""
        }
    }

    /// Where the text being tested comes from — shown so the user is never guessing
    /// whether the Scratchpad holds captured input, a sample, or a run-to-here result.
    private var inputProvenance: String {
        switch sampleSelection {
        case .saved(let id):
            return "Sample: \(allSamples.first { $0.id == id }?.name ?? "Untitled")"
        default:
            return scratchpadProvenance ?? "Scratchpad"
        }
    }

    /// One-line summary of the seeded step's verify ("Check the result") settings.
    private func verifySummary(_ c: StepVerifyConfig) -> String {
        let check: String
        switch c.check {
        case .notEmpty:       check = "result is not empty"
        case .lineColumns:    check = "every line has \(c.expectedColumns) tab-separated column\(c.expectedColumns == 1 ? "" : "s")"
        case .containsWords:  check = "contains: \(c.words)"
        case .matchesPattern: check = "matches a pattern"
        }
        return "Checks \(check) · up to \(c.attempts) tr\(c.attempts == 1 ? "y" : "ies")"
    }

    /// Pass/fail of the current result against the seeded step's check (nil if no check / no result).
    private var verifyOutcome: (passed: Bool, reason: String?)? {
        guard let v = stepVerify, v.enabled, let result = testResult else { return nil }
        let reason = StepVerifier.validate(v, output: result)
        return (reason == nil, reason)
    }

    /// Feeds the persistent bottom Path Bar. When seeded from an Action step:
    /// `Actions ▸ <Action> ▸ Step N ▸ Improve` (first crumbs link back to Actions);
    /// otherwise `Instruction Lab ▸ <Scope> ▸ <Sample>`.
    private func updateBreadcrumb() {
        // In-context (drilled from a step): extend the cascade trail *after* its "Instruction Lab"
        // crumb with this tool's own depth — `Sample: …` (the forwarded text), `Prompt` (when the
        // prompt editor is focused), and `Improve` (when the improve panel is open). 24.1 A/C.
        if appState.editOrigin != nil {
            guard let pbIdx = appState.breadcrumb.firstIndex(where: { $0.label == "Instruction Lab" }) else { return }
            var crumbs = Array(appState.breadcrumb.prefix(pbIdx + 1))
            crumbs.append(BreadcrumbCrumb("Sample: \(inContextSampleName)"))
            if promptFocused || showImprovePanel { crumbs.append(BreadcrumbCrumb("Prompt")) }
            if showImprovePanel { crumbs.append(BreadcrumbCrumb("Improve")) }
            appState.breadcrumb = crumbs
            return
        }
        // Standalone authoring: the shared root, then the scope/sample (or seeded step) location.
        var crumbs = appState.rootCrumbs
        if let seed, let actionID = seed.actionID {
            let actionName = ((try? modelContext.fetch(FetchDescriptor<FormattingPipeline>())) ?? [])
                .first(where: { $0.id == actionID })?.name ?? "Action"
            // Carry a NavTarget so clicking the crumb re-selects *this* action (its scope +
            // selection), not just the Actions mode with the first action defaulted. (Fix c)
            crumbs.append(BreadcrumbCrumb(actionName, target: .action(id: actionID)))
            if let idx = seed.stepIndex { crumbs.append(BreadcrumbCrumb("Step \(idx + 1)")) }
            crumbs.append(BreadcrumbCrumb(seed.openImprove ? "Improve" : "Instruction Lab"))
        } else {
            crumbs.append(BreadcrumbCrumb(scopeFilter?.displayName ?? "All Scopes"))
            switch sampleSelection {
            case .saved(let id):
                crumbs.append(BreadcrumbCrumb(allSamples.first { $0.id == id }?.name ?? "Sample"))
            default:
                crumbs.append(BreadcrumbCrumb("Scratchpad"))
            }
        }
        appState.breadcrumb = crumbs
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                HSplitView {
                    // Input · Instruction · Result — seeded to equal thirds, freely resizable.
                    // The Improve panel slides over the Result column (see resultColumn), so it's
                    // never a fourth column.
                    inputPane
                        .frame(minWidth: 280,
                               idealWidth: max(280, geo.size.width / 3),
                               maxWidth: .infinity)
                    promptPane
                        .frame(minWidth: 320,
                               idealWidth: max(320, geo.size.width / 3),
                               maxWidth: .infinity)
                    resultColumn
                        .frame(minWidth: 300,
                               idealWidth: max(300, geo.size.width / 3),
                               maxWidth: .infinity)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }

            if !isEmbedded {
                Divider()
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .frame(minWidth: isEmbedded ? 720 : 1000, minHeight: isEmbedded ? 460 : 580)
        .background {
            if isEmbedded { VisualEffectBackground() }
        }
        .onAppear { restoreDraft(); applySeed(); updateBreadcrumb() }
        // Persist the *standalone* (Library) draft only. In a document cascade the prompt +
        // scratchpad are the forwarded source's, not your global draft — don't leak them.
        .onChange(of: promptText)     { _, t in
            if appState.editOrigin == nil { UserDefaults.standard.set(t, forKey: Self.draftPromptKey) }
        }
        .onChange(of: scratchpadText) { _, t in
            if appState.editOrigin == nil { UserDefaults.standard.set(t, forKey: Self.draftScratchpadKey) }
            if settingScratchpadProgrammatically {
                settingScratchpadProgrammatically = false   // keep the run-to-here provenance
            } else {
                scratchpadProvenance = nil                  // hand-edited → plain Scratchpad
            }
            markTransformStale()
        }
        .onChange(of: editingText)     { _, _ in markTransformStale() }
        .onChange(of: transformConfig) { _, _ in
            markTransformStale()
            if !improveAvailable { showImprovePanel = false }
        }
        .onChange(of: kind) { _, _ in
            testResult = nil; testError = nil; resultStale = false
            if !improveAvailable { showImprovePanel = false }
        }
        .onChange(of: testResult) { _, _ in
            if showImprovePanel { resetChat() } else { chatNeedsContextRefresh = true }
        }
        .onChange(of: showImprovePanel) { _, isVisible in
            if isVisible && chatNeedsContextRefresh { resetChat() }
            updateBreadcrumb()                       // surface/hide the "Improve" crumb (24.1)
        }
        .onChange(of: promptFocused) { _, _ in updateBreadcrumb() }   // surface/hide the "Prompt" crumb
        .onChange(of: scopeFilter) { _, _ in
            if case .saved = sampleSelection { sampleSelection = .scratchpad }
            testResult = nil; testError = nil
            updateBreadcrumb()
        }
        .onChange(of: sampleSelection) { _, newSelection in
            testResult = nil; testError = nil
            if case .saved(let id) = newSelection,
               let sample = allSamples.first(where: { $0.id == id }) {
                editingName  = sample.name
                editingText  = sample.sampleText
                editingScope = sample.scope
            }
            updateBreadcrumb()
            resultStale = false
        }
        .onChange(of: allSamples.count) { _, _ in
            // A sample deleted elsewhere (e.g. the Text Sample Manager) that was the current
            // input → fall back to Scratchpad so the Input pane never gets stuck in the empty state.
            if case .saved(let id) = sampleSelection, !allSamples.contains(where: { $0.id == id }) {
                sampleSelection = .scratchpad
            }
        }
        .sheet(isPresented: $showingLoadPromptSheet) {
            // Library origin browses everything; Action/Wizard pre-filter to the action's scope.
            LoadExistingPromptSheet(
                scopeFilter: origin == .library ? nil : scopeFilter,
                newSeed: currentInstructionIsEmpty ? nil : SavedPromptSeed(
                    kind: kind,
                    text: promptText,
                    transformConfigJSON: transformConfig.encodedString(),
                    extractConfigJSON: extractConfig.encodedString(),
                    translateConfigJSON: translateConfig.encodedString(),
                    name: "")
            ) { loaded in
                applyLoadedInstruction(loaded)
            }
        }
        .sheet(isPresented: $showingSaveLibrarySheet) {
            SavePromptToLibrarySheet(promptText: promptText,
                                     initialScope: scopeFilter,
                                     nextSortOrder: allSavedPrompts.count,
                                     kind: kind,
                                     transformConfigJSON: transformConfig.encodedString(),
                                     extractConfigJSON: extractConfig.encodedString(),
                                     translateConfigJSON: translateConfig.encodedString())
        }
        .sheet(isPresented: $showingImportActionSheet) {
            LoadFromActionSheet { loaded in promptText = loaded }
        }
        .sheet(isPresented: $showingSampleManager) {
            TextSampleManagerSheet(initialScope: scopeFilter) { pickedID in
                // Selecting/creating in the manager reflects back into the Input pane.
                sampleSelection = .saved(pickedID)
            }
        }
    }

    // MARK: - Bottom run button

    @ViewBuilder
    private var runToolbarContent: some View {
        if isRunning {
            HStack(spacing: 10) {
                if let p = runProgress, p.chunkCount > 1 {
                    PipelineProgressView(progress: p)
                        .frame(maxWidth: 200)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Running…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Stop") {
                    runTask?.cancel(); runTask = nil
                    isRunning = false; runProgress = nil
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button { runInstruction() } label: {
                Label("Test", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canRun)
            .help(runHelpText)
        }
    }

    /// Whether the current instruction can run against the current input.
    private var canRun: Bool {
        guard !activeText.isEmpty else { return false }
        switch kind {
        case .aiPrompt:      return !promptText.isEmpty
        case .extractFields: return extractConfig.fields.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        case .transform:     return true
        case .translate:     return translateConfig.hasTarget
        }
    }

    private var runHelpText: String {
        if activeText.isEmpty { return "Enter or select sample text first" }
        switch kind {
        case .aiPrompt      where promptText.isEmpty: return "Enter a prompt first"
        case .extractFields where !canRun:            return "Add at least one field to extract"
        default:                                      return ""
        }
    }

    /// Dispatches Test to the right engine for the current kind.
    private func runInstruction() {
        switch kind {
        case .aiPrompt:      runPrompt()
        case .extractFields: runExtract()
        case .transform:     runTransform()
        case .translate:     runTranslate()
        }
    }

    /// Runs an on-device translation of the current input to the chosen language.
    private func runTranslate() {
        testResult = nil; testError = nil; runProgress = nil; isRunning = true
        let text = activeText
        let cfg = translateConfig
        runTask = Task { @MainActor in
            guard cfg.hasTarget else {
                testError = "Choose a language to translate to."; isRunning = false; runTask = nil; return
            }
            do {
                // "Into my language" resolves at run time, matching what the pipeline engine does.
                let target = cfg.effectiveTargetCode(
                    systemCode: TranslationCatalog.shared.systemLanguageCode)
                let out = try await TranslationCoordinator.shared.translate(
                    text, sourceCode: cfg.sourceLanguageCode, targetCode: target)
                if !Task.isCancelled { testResult = out }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { testError = error.localizedDescription }
            }
            isRunning = false; runTask = nil
        }
    }

    /// Runs the deterministic transform once, on demand (instant, local).
    private func runTransform() {
        guard kind == .transform else { return }
        testError = nil
        let text = activeText
        testResult = text.isEmpty ? nil : TextTransformEngine.apply(transformConfig, to: text)
        resultStale = false
    }

    /// Marks a computed transform result out of date when its input or config changes.
    private func markTransformStale() {
        if kind == .transform && testResult != nil { resultStale = true }
    }

    /// Guided extraction: the model fills the declared fields, then they're combined locally.
    private func runExtract() {
        testResult = nil; testError = nil; runProgress = nil; isRunning = true
        let text = activeText
        let cfg = extractConfig
        runTask = Task { @MainActor in
            let specs = cfg.fields
                .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ExtractionFieldSpec(name: $0.name, typeHint: $0.type.rawValue, description: $0.fieldDescription) }
            if specs.isEmpty {
                testError = "Add at least one field to extract."
                isRunning = false; runTask = nil
                return
            }
            do {
                let record = try await ModelProviderRegistry.current.extractFields(from: text, fields: specs)
                if !Task.isCancelled { testResult = cfg.formatRecord(record) }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { testError = error.localizedDescription }
            }
            isRunning = false; runTask = nil
        }
    }

    // MARK: - Test bench (left pane): input editor on top, scope pop-up, samples list below

    /// The left pane. The selected input editor fills the top; below it (except in the
    /// document-source cascade, where the input is the forwarded text and there's nothing
    /// to pick) sit the optional Scope pop-up — shown only for the Library origin, since
    /// Action/Wizard already know the scope — and the Samples list.
    private var inputPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Input").font(.title3.bold())
                Spacer()
                samplePickerButton
            }
            .frame(height: 44)
            .padding(.horizontal, 14)
            .background(.bar)

            Divider()

            inputEditorBody
        }
    }

    /// Height of the control strip that sits directly under each column header — the sample
    /// name/scope row in Input, the instruction-kind picker in Instruction.
    ///
    /// Shared and fixed so the two columns' editors start on the same line. They used to be laid out
    /// independently and only *happened* to line up for a saved sample; the Scratchpad had no strip at
    /// all, so its editor floated ~18pt higher than the Instruction editor beside it.
    private static let columnStripHeight: CGFloat = 40

    private var inputIsScratchpad: Bool {
        if case .saved = sampleSelection { return false }
        return true
    }

    private var inputSelectionTitle: String {
        switch sampleSelection {
        case .saved(let id): return allSamples.first { $0.id == id }?.name ?? "Sample"
        default:             return appState.editOrigin != nil ? inContextSampleName : "Scratchpad"
        }
    }

    /// The sample-selection popover trigger. Disabled in a document cascade, where the input is
    /// the forwarded source text and there's nothing to pick.
    private var samplePickerButton: some View {
        Button {
            showingSamplePicker.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: inputIsScratchpad
                      ? (appState.editOrigin != nil ? "doc.text" : "pencil.and.scribble")
                      : "text.quote")
                Text(inputSelectionTitle).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(appState.editOrigin != nil)
        .popover(isPresented: $showingSamplePicker, arrowEdge: .bottom) { samplePickerPopover }
        .help("Choose the text to test against")
    }

    private var samplePickerPopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Scope").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: scopeTagBinding) {
                    Text("Any").tag(nil as PipelineScope?)
                    ForEach(PipelineScope.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s as PipelineScope?)
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            List {
                Button {
                    sampleSelection = .scratchpad
                    showingSamplePicker = false
                } label: {
                    Label("Scratchpad", systemImage: "pencil.and.scribble")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if !filteredSamples.isEmpty {
                    Section("Saved") {
                        ForEach(filteredSamples, id: \.id) { sample in
                            Button {
                                sampleSelection = .saved(sample.id)
                                showingSamplePicker = false
                            } label: {
                                SampleRowView(sample: sample)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(width: 260, height: 280)

            Divider()

            Button {
                showingSamplePicker = false
                showingSampleManager = true
            } label: {
                Label("Manage samples…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .frame(width: 260)
    }

    // MARK: - Saved Prompts picker (Instruction pane) — mirrors the sample picker

    private func savedPrompts(in scope: PipelineScope) -> [SavedPrompt] {
        allSavedPrompts.filter { $0.scopeTag == scope }
    }
    private var generalSavedPrompts: [SavedPrompt] {
        allSavedPrompts.filter { $0.scopeTag == nil }
    }

    private func promptPickRow(_ p: SavedPrompt) -> some View {
        Button {
            applyLoadedInstruction(p)
            showingPromptPicker = false
        } label: {
            Label(p.name.isEmpty ? "Untitled" : p.name, systemImage: Self.kindIcon(p.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var promptPickerPopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Scope").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $promptScopeFilter) {
                    Text("All Scopes").tag(nil as PipelineScope?)
                    ForEach(PipelineScope.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s as PipelineScope?)
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            List {
                if allSavedPrompts.isEmpty {
                    Text("No saved instructions yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let f = promptScopeFilter {
                    let scoped = savedPrompts(in: f)
                    if !scoped.isEmpty { Section(f.displayName) { ForEach(scoped, id: \.id) { promptPickRow($0) } } }
                    if !generalSavedPrompts.isEmpty { Section("General (Any)") { ForEach(generalSavedPrompts, id: \.id) { promptPickRow($0) } } }
                } else {
                    ForEach(PipelineScope.allCases, id: \.self) { s in
                        let group = savedPrompts(in: s)
                        if !group.isEmpty { Section(s.displayName) { ForEach(group, id: \.id) { promptPickRow($0) } } }
                    }
                    if !generalSavedPrompts.isEmpty { Section("General (Any)") { ForEach(generalSavedPrompts, id: \.id) { promptPickRow($0) } } }
                }
            }
            .listStyle(.inset)
            .frame(width: 300, height: 320)

            if kind == .aiPrompt {
                Divider()
                HStack(spacing: 8) {
                    Button {
                        showingPromptPicker = false
                        showingImportActionSheet = true
                    } label: {
                        Label("Load from Action…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(10)
            }
        }
        .frame(width: 300)
    }

    @ViewBuilder
    private var inputEditorBody: some View {
        switch sampleSelection {
        case .saved:
            if let sample = selectedSample { savedSampleEditor(sample) }
            else { emptySelectionView }
        default:
            scratchpadEditor
        }
    }

    private var scratchpadEditor: some View {
        VStack(spacing: 0) {
            // The hint lives in a strip of the shared height — same position the saved-sample name row
            // and the Instruction kind picker occupy — so the editor below starts on the same line as
            // the instruction editor. Kept to one line for that reason; the full wording is the tooltip.
            HStack {
                Text(appState.editOrigin != nil
                     ? "Forwarded from the action — your sources aren't changed."
                     : "Temporary text to test against. Paste or type, then Run.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(appState.editOrigin != nil
                          ? "Forwarded from the action — testing against this text. Results stay here; your sources aren't changed."
                          : "Temporary text to test against. Paste or type, then Run.")
                Spacer()
            }
            .frame(height: Self.columnStripHeight)
            .padding(.horizontal, 14)

            Divider()

            ScrollView {
                TextEditor(text: $scratchpadText)
                    .font(.body)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    .overlay(alignment: .bottomTrailing) { DictateButton().padding(8) }
                    .padding(16)
            }

            inputFooter(charCount: scratchpadText.count,
                        clear: scratchpadText.isEmpty ? nil : { scratchpadText = "" })
        }
    }

    private func savedSampleEditor(_ sample: PromptSample) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Untitled Sample", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $editingScope) {
                    ForEach(PipelineScope.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(width: 130)
            }
            .frame(height: Self.columnStripHeight)
            .padding(.horizontal, 14)

            Divider()

            ScrollView {
                TextEditor(text: $editingText)
                    .font(.body)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    .overlay(alignment: .bottomTrailing) { DictateButton().padding(8) }
                    .padding(16)
            }

            if sampleIsDirty {
                Divider()
                HStack(spacing: 8) {
                    Text("Unsaved changes").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Discard") {
                        editingName = sample.name; editingText = sample.sampleText; editingScope = sample.scope
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Button("Save") {
                        sample.name = editingName; sample.sampleText = editingText; sample.scope = editingScope
                        try? modelContext.save()
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                .frame(height: 46).padding(.horizontal, 14).background(.bar)
            } else {
                inputFooter(charCount: editingText.count, clear: nil)
            }
        }
    }

    private func inputFooter(charCount: Int, clear: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Text("\(charCount.formatted()) chars").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            if let clear {
                Button("Clear", action: clear)
                    .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
            }
            if inputIsScratchpad {
                Button("Save as sample…") { saveActiveTextAsSample() }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(activeText.isEmpty || allSamples.count >= sampleLimit)
                    .help("Save this text as a reusable sample (\(sampleLimit) max)")
            }
        }
        .frame(height: 46).padding(.horizontal, 14).background(.bar)
    }

    /// Creates a saved sample from the current Scratchpad text and selects it for renaming.
    private func saveActiveTextAsSample() {
        guard allSamples.count < sampleLimit else { return }
        let sample = PromptSample(name: "Sample \(allSamples.count + 1)",
                                  sampleText: scratchpadText,
                                  scope: scopeFilter ?? .source,
                                  sortOrder: allSamples.count)
        modelContext.insert(sample)
        try? modelContext.save()
        sampleSelection = .saved(sample.id)
    }

    /// Persists the current Result as a reusable input sample (banking a milestone).
    private func saveResultAsSample(_ text: String) {
        guard allSamples.count < sampleLimit else { return }
        let sample = PromptSample(name: "Sample \(allSamples.count + 1)",
                                  sampleText: text,
                                  scope: scopeFilter ?? .source,
                                  sortOrder: allSamples.count)
        modelContext.insert(sample)
        try? modelContext.save()
    }

    /// Moves the current Result into the Input (Scratchpad) to chain into the next instruction —
    /// the frequent, ephemeral step of the iterate loop. Persisting is the separate "Save".
    private func useResultAsInput(_ text: String) {
        settingScratchpadProgrammatically = true
        scratchpadProvenance = "From previous result"
        scratchpadText = text
        if case .scratchpad = sampleSelection {} else { sampleSelection = .scratchpad }
        testResult = nil; testError = nil; resultStale = false
    }

    private var scopeTagBinding: Binding<PipelineScope?> {
        Binding(get: { scopeFilter }, set: { scopeFilter = $0 })
    }

    private var emptySelectionView: some View {
        ContentUnavailableView(
            "No Sample Selected",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Select a sample from the list, or use Scratchpad to test without saving.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Prompt panel (right, flexible — takes priority over the sample column)

    /// Persistent "Subject:" chip (23.5) — makes clear *what* Run Prompt tests against, and
    /// that the Instruction Lab is **Test-only** (authoring): `📄 <source>` when drilled in
    /// from a document, else `🧩 <sample>` (a saved sample or the scratchpad).
    private var subjectLabel: String {
        if let origin = appState.editOrigin {
            return "📄 " + (origin.sourceName.isEmpty ? "source" : origin.sourceName)
        }
        if case .saved(let id) = sampleSelection {
            return "🧩 " + (allSamples.first { $0.id == id }?.name ?? "Sample")
        }
        return "🧩 Scratchpad"
    }

    /// Name of the forwarded sample for the in-context breadcrumb (24.1): "Step N text" when
    /// drilled from a step, else the seed's sample name.
    private var inContextSampleName: String {
        if let idx = seed?.stepIndex { return "Step \(idx + 1) text" }
        let name = seed?.sampleName ?? ""
        return name.isEmpty ? "forwarded text" : name
    }

    private var subjectChip: some View {
        HStack(spacing: 4) {
            Text("Testing:").font(.caption2).foregroundStyle(.tertiary)
            Text(subjectLabel).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .help("Run Prompt tests against this subject. Results stay here — they don't change your sources.")
    }

    private var promptPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Instruction", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()

                Button { showingPromptPicker.toggle() } label: {
                    Label("Load", systemImage: "books.vertical").lineLimit(1)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showingPromptPicker, arrowEdge: .bottom) { promptPickerPopover }
                .help("Load a saved instruction")

                Menu {
                    saveItems
                    if kind == .aiPrompt {
                        Button("Copy") { copyPrompt() }.disabled(promptText.isEmpty)
                    }
                    Divider()
                    Button("Manage Prompts…") { showingLoadPromptSheet = true }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Save or manage instructions")

                if kind == .aiPrompt {
                    Button { promptText = "" } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(promptText.isEmpty)
                    .help("Clear the prompt")
                }

                if improveAvailable {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showImprovePanel.toggle() }
                    } label: {
                        Image(systemName: "wand.and.sparkles")
                            .foregroundStyle(showImprovePanel ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(showImprovePanel
                          ? "Hide AI help"
                          : (kind == .transform ? "Improve the pattern with AI" : "Improve the prompt with AI"))
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .background(.bar)

            Divider()

            kindSwitcher

            Divider()

            ScrollView {
                instructionEditor
                    .padding(16)
            }

            Divider()

            runBar
        }
    }

    /// AI Prompt · Transform · Extract Fields — what this instruction does.
    private var kindSwitcher: some View {
        Picker("Instruction kind", selection: $kind) {
            Text("AI Prompt").tag(PipelineStepKind.aiPrompt)
            Text("Transform").tag(PipelineStepKind.transform)
            Text("Extract Fields").tag(PipelineStepKind.extractFields)
            Text("Translate").tag(PipelineStepKind.translate)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(height: Self.columnStripHeight)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var instructionEditor: some View {
        switch kind {
        case .aiPrompt:
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $promptText)
                        .font(.body)
                        .frame(minHeight: 200)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .focused($promptFocused)

                    if promptText.isEmpty {
                        Text("Enter your prompt here…")
                            .foregroundStyle(.tertiary)
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                }
                .background(.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    DictateButton().padding(8)
                }

                HStack {
                    Spacer()
                    Text("\(promptText.count) / \(AppConstants.maxPromptCharacters) chars")
                        .font(.caption2)
                        .foregroundStyle(promptText.count > AppConstants.maxPromptCharacters
                            ? AnyShapeStyle(.red)
                            : AnyShapeStyle(.tertiary))
                }
            }
        case .transform:
            TransformConfigEditor(config: $transformConfig)
        case .extractFields:
            ExtractFieldsEditor(config: $extractConfig)
        case .translate:
            // Hand over the text being tested so the source language is detected from what will
            // actually run, not assumed from the system language (26.2).
            TranslateConfigEditor(config: $translateConfig, sampleText: activeText)
        }
    }

    // MARK: - Result column (right pane), with the Improve panel sliding over it

    private var resultColumn: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Result").font(.title3.bold())
                    Spacer()
                    if let outcome = verifyOutcome {
                        Label(outcome.passed ? "Passed the check" : "Failed the check",
                              systemImage: outcome.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(outcome.passed ? Color.green : Color.red)
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 14)
                .background(.bar)

                Divider()

                resultBody

                Divider()

                resultFooter
            }

            if showImprovePanel {
                improvePanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .trailing))
            }
        }
    }

    /// Result pane footer — mirrors the Input/Instruction footers (output size + chaining actions).
    private var resultFooter: some View {
        HStack(spacing: 10) {
            if let result = testResult {
                Text("\(result.count.formatted()) chars")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if let result = testResult {
                Button { useResultAsInput(result) } label: {
                    Label("Use as Input", systemImage: "arrow.left.circle").font(.caption)
                }
                .buttonStyle(.borderless).controlSize(.small)
                .help("Send this output to the Input pane to chain it into your next instruction")

                Button { saveResultAsSample(result) } label: {
                    Label("Save", systemImage: "tray.and.arrow.down").font(.caption)
                }
                .buttonStyle(.borderless).controlSize(.small)
                .disabled(allSamples.count >= sampleLimit)
                .help("Save this output as a reusable sample")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless).controlSize(.small)
            }
        }
        .frame(height: 46)
        .padding(.horizontal, 14)
        .background(.bar)
    }

    @ViewBuilder
    private var resultBody: some View {
        if testResult == nil && testError == nil {
            ContentUnavailableView("No Result Yet",
                                   systemImage: "play.circle",
                                   description: Text("Run the instruction to see its output here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let err = testError {
                        Text(err).font(.caption).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let outcome = verifyOutcome, !outcome.passed, let reason = outcome.reason {
                        Text(reason).font(.caption).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let result = testResult {
                        PromptBuilderResultText(result)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Run bar: what the prompt runs against + optional "Load step input" + Run/Stop.
    private var runBar: some View {
        HStack(spacing: 10) {
            if let idx = rthStepIndex, idx > 0 {
                Button { runUpToHere() } label: {
                    Label("Load step input", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRunning || activeText.isEmpty)
                .help("Run the earlier steps of this action on the selected input and load the result — the real input to the step you're improving.")
            }

            subjectChip

            if let v = stepVerify, v.enabled {
                Label(verifySummary(v), systemImage: "checkmark.shield")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("This step's “Check the result” settings from the Action Editor.")
            }

            if kind == .transform && resultStale {
                Label("Out of date", systemImage: "exclamationmark.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("The input or pattern changed — press Test to update the result.")
            }

            Spacer()
            runToolbarContent
        }
        .frame(height: 46)
        .padding(.horizontal, 16)
        .background(.bar)
    }

    // MARK: - Contextual Save (Phase 25.2)

    /// Save/step actions folded into the Library menu (above the Browse/Import section). Origin-
    /// dependent: the Library saves to the prompt library; an Action can update/append a step or
    /// save-to-library/copy; a document-source test saves-to-library or copies. Disabled while the
    /// prompt is empty; Browse/Import stay enabled regardless.
    /// Whether the AI-help panel applies to the current instruction: prompts (improve wording)
    /// and Find & Replace transforms (improve the regex). Other transforms have nothing to improve.
    private var improveAvailable: Bool {
        switch kind {
        case .aiPrompt:      return !promptText.isEmpty
        case .transform:     return transformConfig.type == .findReplace
        case .extractFields: return false
        case .translate:     return false
        }
    }

    /// Save items for the "Saved Prompts" menu — save to the reusable library (any kind) plus,
    /// when the Lab was opened from an action, save back to that action as a step.
    @ViewBuilder private var saveItems: some View {
        Button("Save to Library…") { showingSaveLibrarySheet = true }
            .disabled(currentInstructionIsEmpty)
        if rthStepIndex != nil {
            Button("Update This Step") { updateSeededStep() }.disabled(currentInstructionIsEmpty)
        }
        if rthActionID != nil {
            Button("Add as New Step") { addStepToSeededAction() }.disabled(currentInstructionIsEmpty)
        }
    }

    /// Whether the current instruction has nothing worth saving/running.
    private var currentInstructionIsEmpty: Bool {
        switch kind {
        case .aiPrompt:
            return promptText.isEmpty
        case .transform:
            return transformConfig.type == .findReplace && transformConfig.find.isEmpty
        case .extractFields:
            return !extractConfig.fields.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        case .translate:
            return !translateConfig.hasTarget
        }
    }

    /// Loads a saved instruction (any kind) into the Lab.
    private func applyLoadedInstruction(_ p: SavedPrompt) {
        kind = p.kind
        switch p.kind {
        case .aiPrompt:      promptText = p.text
        case .transform:     transformConfig = p.transformConfig
        case .extractFields: extractConfig = p.extractConfig
        case .translate:     translateConfig = p.translateConfig
        }
    }

    /// SF Symbol for a saved instruction's kind — disambiguates the quick-pick list.
    static func kindIcon(_ k: PipelineStepKind) -> String {
        switch k {
        case .aiPrompt:      return "sparkles"
        case .transform:     return "wrench.and.screwdriver"
        case .extractFields: return "tablecells"
        case .translate:     return "globe"
        }
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(promptText, forType: .string)
    }

    private func fetchPipeline(_ id: UUID) -> FormattingPipeline? {
        ((try? modelContext.fetch(FetchDescriptor<FormattingPipeline>())) ?? []).first { $0.id == id }
    }

    /// Overwrites the seeded step's prompt with the current text, then returns to the action.
    private func updateSeededStep() {
        guard let id = rthActionID, let idx = rthStepIndex,
              let pipeline = fetchPipeline(id) else { return }
        let steps = pipeline.sortedSteps
        guard idx >= 0, idx < steps.count else { return }
        applyInstruction(to: steps[idx])
        try? modelContext.save()
        navigateToAction(id)
    }

    /// Appends a new step (with the current instruction) to the seeded action, then returns to it.
    private func addStepToSeededAction() {
        guard let id = rthActionID, let pipeline = fetchPipeline(id) else { return }
        let order = (pipeline.steps ?? []).count
        let step = PipelineStep(name: "Step \(order + 1)", prompt: "", sortOrder: order)
        applyInstruction(to: step)
        modelContext.insert(step)
        step.pipeline  = pipeline
        pipeline.steps = (pipeline.steps ?? []) + [step]
        try? modelContext.save()
        navigateToAction(id)
    }

    /// Writes the current instruction (kind + its prompt/config) onto a step.
    private func applyInstruction(to step: PipelineStep) {
        step.kind = kind
        switch kind {
        case .aiPrompt:      step.prompt = promptText
        case .transform:     step.transformConfig = transformConfig
        case .extractFields: step.extractConfig = extractConfig
        case .translate:     step.translateConfig = translateConfig
        }
    }

    /// Lands the user on the action they just saved into (item #6 flow).
    private func navigateToAction(_ id: UUID) {
        appState.editOrigin = nil
        appState.actionToOpen = id
        appState.workspaceMode = .actions
        if !isEmbedded { dismiss() }
    }

    // MARK: - AI Improvement chat panel (slide in from right)

    private var improvePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label(kind == .transform ? "Improve Pattern" : "Improve Prompt", systemImage: "wand.and.sparkles")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showImprovePanel = false }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Hide AI help")
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .background(.bar)

            improveContextStrip

            Divider()

            chatMessagesView

            Divider()

            chatInputArea
        }
    }

    /// Compact reminder of what the assistant is looking at. The panel covers the Result pane,
    /// so the Input · Instruction · Output first lines are surfaced here instead.
    private var improveContextStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            improveContextRow("Input", firstLine(activeText))
            improveContextRow(kind == .transform ? "Pattern" : "Instruction", firstLine(instructionSummaryText))
            improveContextRow("Output", testResult == nil ? "— not run yet —" : firstLine(testResult!))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func improveContextRow(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private func firstLine(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        let line = trimmed.components(separatedBy: .newlines).first ?? trimmed
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    /// A one-line description of the current instruction, for the context strip.
    private var instructionSummaryText: String {
        switch kind {
        case .aiPrompt: return promptText
        case .transform:
            if transformConfig.type == .findReplace {
                return "s/\(transformConfig.find)/\(transformConfig.replace)/"
            }
            return transformConfig.type.displayName
        case .extractFields:
            let names = extractConfig.fields.map(\.name).filter { !$0.isEmpty }
            return names.isEmpty ? "(no fields)" : names.joined(separator: ", ")
        case .translate:
            guard translateConfig.hasTarget else { return "(no language)" }
            return TranslationCatalog.shared.summary(for: translateConfig)
        }
    }

    /// Applies an AI suggestion — a rewritten prompt, or a regex pattern into the Find field.
    private func applySuggestion(_ text: String, isPattern: Bool) {
        if isPattern {
            transformConfig.find = text
            if !transformConfig.useRegex { transformConfig.useRegex = true }
        } else {
            promptText = text
        }
    }

    private var chatMessagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chatMessages.isEmpty && !isChatting {
                        VStack(spacing: 8) {
                            Image(systemName: "wand.and.sparkles")
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                            if testResult == nil {
                                Text(kind == .transform
                                     ? "Add input and a pattern — then ask the assistant to help build or fix your regex."
                                     : "Run the prompt first so the assistant can see the output it produced — then ask what went wrong.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button {
                                    runInstruction()
                                } label: {
                                    Label("Test", systemImage: "play.fill")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!canRun || isRunning)
                            } else {
                                Text(kind == .transform
                                     ? "Ask the assistant to write or fix your pattern, or describe what you want matched."
                                     : "Ask why your prompt produced this output, request improvements, or describe what you wanted instead.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .padding(.horizontal, 16)
                    }

                    ForEach(chatMessages) { msg in
                        PromptChatMessageRow(message: msg) { suggested in
                            applySuggestion(suggested, isPattern: msg.suggestionIsPattern)
                        }
                        .id(msg.id)
                    }

                    if isChatting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .id("thinking")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: chatMessages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") }
            }
            .onChange(of: isChatting) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") }
            }
        }
    }

    private var chatInputArea: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $chatInput)
                    .font(.callout)
                    .frame(minHeight: 56, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .disabled(isChatting)

                if chatInput.isEmpty {
                    Text("Ask about this result, or describe what you wanted…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) { DictateButton().padding(6) }

            HStack {
                Button("New Conversation") { resetChat() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .disabled(chatMessages.isEmpty && !isChatting)

                Spacer()

                if isChatting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Button("Stop") {
                            chatTask?.cancel(); chatTask = nil
                            isChatting = false
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Button { sendChatMessage() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(
                        chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary : Color.accentColor
                    )
                    .disabled(chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (⌘Return)")
                }
            }
        }
        .padding(12)
        .background(.bar)
    }

    // MARK: - Actions

    private func runPrompt() {
        testResult = nil
        testError  = nil
        runProgress = nil
        isRunning  = true
        let prompt     = promptText
        let sampleText = activeText
        runTask = Task { @MainActor in
            do {
                let result = try await DocumentFormattingService()
                    .formatWithPrompt(sourceText: sampleText, systemPrompt: prompt) { p in
                        runProgress = p
                    }
                if !Task.isCancelled { testResult = result }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { testError = error.localizedDescription }
            }
            isRunning = false
            runProgress = nil
            runTask   = nil
        }
    }

    private func makeSession() -> any ModelSession {
        let instructions = kind == .transform ? makeRegexInstructions() : makePromptInstructions()
        return ModelProviderRegistry.current.makeSession(instructions: instructions)
    }

    private func makePromptInstructions() -> String {
        var instructions = """
        You are an AI prompt engineering assistant inside an app called Textifyr. \
        Prompts in this app are system instructions given to Apple Intelligence to \
        process text (fix grammar, summarise, translate, format meeting notes, etc.).

        CURRENT PROMPT BEING TESTED:
        \(promptText.isEmpty ? "(none entered yet)" : promptText)
        """

        if let result = testResult {
            let preview = result.count > 800 ? String(result.prefix(800)) + "\n[…truncated]" : result
            instructions += "\n\nRESULT WHEN THE PROMPT WAS RUN:\n\(preview)"
        } else {
            instructions += "\n\nRESULT: The prompt has not been run yet."
        }

        instructions += """

        Your role:
        - Answer questions about why the prompt produced this output
        - Suggest improved prompts when asked
        - Help diagnose errors or unexpected behaviour
        - Explain prompt engineering concepts concisely
        - Keep responses short and focused

        When you suggest an improved prompt, end your response with exactly this — \
        no extra text after it:
        SUGGESTED PROMPT:
        [the complete improved prompt, nothing else]
        """

        return instructions
    }

    private func makeRegexInstructions() -> String {
        let sampleIn = activeText.count > 800 ? String(activeText.prefix(800)) + "\n[…truncated]" : activeText
        var instructions = """
        You are a regular-expression assistant inside an app called Textifyr. The user is building a \
        Find & Replace transform that runs on macOS using NSRegularExpression (ICU / Foundation regex \
        syntax). Help them write or fix the Find pattern, and the Replacement template when useful \
        ($1, $2 … are capture groups; \\t is a Tab and \\n a newline in the replacement).

        CURRENT FIND PATTERN:
        \(transformConfig.find.isEmpty ? "(empty)" : transformConfig.find)
        CURRENT REPLACEMENT:
        \(transformConfig.replace.isEmpty ? "(empty)" : transformConfig.replace)
        REGEX MODE: \(transformConfig.useRegex ? "on" : "off (currently literal)")

        INPUT SAMPLE:
        \(sampleIn.isEmpty ? "(none provided yet)" : sampleIn)
        """

        if let result = testResult {
            let preview = result.count > 800 ? String(result.prefix(800)) + "\n[…truncated]" : result
            instructions += "\n\nCURRENT OUTPUT (the pattern applied to the input):\n\(preview)"
        }

        instructions += """

        Rules for correct patterns:
        - Use quantifiers; never repeat a token literally. "one or more X" = X+ · "two or more X" = X{2,} · "exactly 3 X" = X{3} · "between 2 and 5 X" = X{2,5} · "optional X" = X?. For example "2 or more n" is n{2,} — NOT nnn or (n)(n)(n).
        - Escape metacharacters . * + ? [ ] ( ) { } | \\ ^ $ when matching them literally.
        - Use \\d \\w \\s \\b and anchors ^ $ where the request implies them.
        - Prefer the simplest pattern that matches exactly what was asked — nothing more.

        Keep responses short. Explain briefly, then when you propose a pattern end your response with \
        exactly this and nothing after it:
        SUGGESTED PATTERN:
        [the regular expression only — no slashes, no quotes, no explanation]
        """

        return instructions
    }

    private func sendChatMessage() {
        let trimmed = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isChatting else { return }

        guard ModelProviderRegistry.current.isAvailable else {
            chatMessages.append(PromptChatMessage(role: .assistant, rawContent:
                "Apple Intelligence is not available on this device or is not enabled in Settings."))
            return
        }

        chatInput = ""
        chatMessages.append(PromptChatMessage(role: .user, rawContent: trimmed))
        isChatting = true

        if chatSession == nil { chatSession = makeSession() }
        let session = chatSession!

        chatTask = Task { @MainActor in
            do {
                let response = try await session.respond(to: trimmed)
                if !Task.isCancelled {
                    chatMessages.append(PromptChatMessage(role: .assistant, rawContent: response))
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    chatMessages.append(PromptChatMessage(role: .assistant,
                        rawContent: "Something went wrong: \(error.localizedDescription)"))
                }
            }
            isChatting = false
            chatTask = nil
        }
    }

    private func resetChat() {
        chatTask?.cancel()
        chatTask = nil
        chatMessages = []
        chatSession = nil
        isChatting = false
        chatInput = ""
        chatNeedsContextRefresh = false
    }

    private func restoreDraft() {
        // Only the standalone (Library) flow restores the saved draft. In a document cascade,
        // `applySeed` fills the prompt + scratchpad from the forwarded source instead.
        guard appState.editOrigin == nil else { scratchpadText = ""; return }
        promptText     = UserDefaults.standard.string(forKey: Self.draftPromptKey) ?? ""
        scratchpadText = UserDefaults.standard.string(forKey: Self.draftScratchpadKey) ?? ""
    }

    /// Applies an optional seed (from an Action step's "Improve" button): loads the
    /// step's prompt, opens the improve panel, and records run-to-here context.
    private func applySeed() {
        guard let seed else { return }
        if !seed.prompt.isEmpty { promptText = seed.prompt }
        kind = seed.kind
        if !seed.transformConfigJSON.isEmpty { transformConfig = TextTransformConfig.decode(seed.transformConfigJSON) }
        if !seed.extractConfigJSON.isEmpty   { extractConfig   = ExtractFieldsConfig.decode(seed.extractConfigJSON) }
        rthActionID  = seed.actionID
        rthStepIndex = seed.stepIndex

        // Action origin already knows its scope — pre-filter the samples list and the
        // Prompt Library to it (the scope pop-up stays hidden). (Phase 25.2)
        if let id = seed.actionID,
           let pipeline = ((try? modelContext.fetch(FetchDescriptor<FormattingPipeline>())) ?? [])
                .first(where: { $0.id == id }) {
            scopeFilter = pipeline.scope
        }

        // Seeded from a source (e.g. a flagged source's "Improve in Instruction Lab"):
        // stage its text as the Scratchpad sample so the user iterates against the exact
        // input that failed (21.5/22.9).
        if !seed.sampleText.isEmpty {
            settingScratchpadProgrammatically = true
            scratchpadText = seed.sampleText
            scratchpadProvenance = seed.sampleName.isEmpty ? "Source" : "Source: \(seed.sampleName)"
            sampleSelection = .scratchpad
        }

        // Load the originating step's "Check the result" settings so the test surface
        // can show the criteria and report pass/fail (22.0c).
        if let id = seed.actionID, let idx = seed.stepIndex,
           let pipeline = ((try? modelContext.fetch(FetchDescriptor<FormattingPipeline>())) ?? [])
                .first(where: { $0.id == id }) {
            let steps = pipeline.sortedSteps
            if idx >= 0, idx < steps.count {
                let vc = steps[idx].verifyConfig
                if vc.enabled { stepVerify = vc }
            }
        }

        if seed.openImprove {
            chatNeedsContextRefresh = true
            showImprovePanel = true
        }
    }

    /// Runs steps 0..<stepIndex of the originating action on the active sample text
    /// and loads the result into the Scratchpad — the true input to the step being
    /// improved (Phase 21.4 `textEnteringStep`).
    private func runUpToHere() {
        guard let id = rthActionID, let idx = rthStepIndex, idx > 0 else { return }
        let source = activeText
        guard !source.isEmpty else { return }
        let pipelines = (try? modelContext.fetch(FetchDescriptor<FormattingPipeline>())) ?? []
        guard let pipeline = pipelines.first(where: { $0.id == id }) else {
            testError = "Couldn't find the action to run the earlier steps."
            return
        }
        testError = nil
        runProgress = nil
        isRunning = true
        runTask = Task { @MainActor in
            do {
                let input = try await DocumentFormattingService().textEnteringStep(
                    pipeline: pipeline, sourceText: source, index: idx) { p in runProgress = p }
                if !Task.isCancelled {
                    settingScratchpadProgrammatically = true
                    scratchpadText = input
                    scratchpadProvenance = "Step \(idx + 1) input (after step\(idx == 1 ? " 1" : "s 1…\(idx)"))"
                    sampleSelection = .scratchpad
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { testError = error.localizedDescription }
            }
            isRunning = false
            runProgress = nil
            runTask = nil
        }
    }
}

// MARK: - Chat message model

private struct PromptChatMessage: Identifiable {
    let id = UUID()
    enum Role { case user, assistant }
    let role: Role
    let displayContent: String
    let suggestedPrompt: String?
    let suggestionIsPattern: Bool

    init(role: Role, rawContent: String) {
        self.role = role
        let parsed = Self.parse(rawContent)
        self.displayContent = parsed.display
        self.suggestedPrompt = parsed.suggestion
        self.suggestionIsPattern = parsed.isPattern
    }

    static func parse(_ content: String) -> (display: String, suggestion: String?, isPattern: Bool) {
        for (marker, isPattern) in [("SUGGESTED PATTERN:", true), ("SUGGESTED PROMPT:", false)] {
            if let range = content.range(of: marker, options: .caseInsensitive) {
                let display = String(content[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let suggestion = String(content[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (display.isEmpty ? content : display, suggestion.isEmpty ? nil : suggestion, isPattern)
            }
        }
        return (content.trimmingCharacters(in: .whitespacesAndNewlines), nil, false)
    }
}

// MARK: - Chat message row

private struct PromptChatMessageRow: View {
    let message: PromptChatMessage
    let onUseAsPrompt: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 32) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                Text(message.displayContent)
                    .font(.callout)
                    .textSelection(.enabled)
                    .multilineTextAlignment(message.role == .user ? .trailing : .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.role == .user
                            ? Color.accentColor.opacity(0.15)
                            : Color(nsColor: .controlBackgroundColor)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if let suggested = message.suggestedPrompt {
                    Button {
                        onUseAsPrompt(suggested)
                    } label: {
                        Label(message.suggestionIsPattern ? "Use as Pattern" : "Use as Prompt",
                              systemImage: "arrow.up.right.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }
}

// MARK: - Sample row

private struct SampleRowView: View {
    let sample: PromptSample

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sample.name.isEmpty ? "Untitled" : sample.name)
                .font(.callout)
                .lineLimit(1)
            Text(sample.scope.displayName)
                .font(.caption2)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Text Sample Manager sheet (app-wide sample CRUD)

/// Standalone add/edit/delete for the reusable test-text samples. Reached from the Instruction
/// Lab's Input picker and (later) the Tools menu. Editing is explicit-save, matching the app.
struct TextSampleManagerSheet: View {
    var initialScope: PipelineScope?
    /// Called on Done with the currently selected sample, so a caller can adopt it.
    var onSelect: ((UUID) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PromptSample.sortOrder) private var allSamples: [PromptSample]

    @State private var selectedID: UUID?
    @State private var editingName = ""
    @State private var editingText = ""
    @State private var editingScope: PipelineScope = .source
    @State private var didInit = false

    private let sampleLimit = AppConstants.maxPromptSamples

    private var selected: PromptSample? { allSamples.first { $0.id == selectedID } }
    private var isDirty: Bool {
        guard let s = selected else { return false }
        return editingName != s.name || editingText != s.sampleText || editingScope != s.scope
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Text Sample Manager").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14).background(.bar)

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(allSamples, id: \.id) { sample in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sample.name.isEmpty ? "Untitled" : sample.name)
                                    .font(.callout).lineLimit(1)
                                Text(sample.scope.displayName)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .tag(sample.id)
                        }
                    }
                    .listStyle(.inset)

                    Divider()

                    HStack(spacing: 0) {
                        Button { addSample() } label: { Image(systemName: "plus").frame(width: 28, height: 22) }
                            .buttonStyle(.borderless).disabled(allSamples.count >= sampleLimit)
                            .help("Add sample (\(sampleLimit) max)")
                        Divider().frame(height: 14)
                        Button { if let s = selected { deleteSample(s) } } label: { Image(systemName: "minus").frame(width: 28, height: 22) }
                            .buttonStyle(.borderless).disabled(selected == nil)
                            .help("Delete selected sample")
                        Spacer()
                    }
                    .padding(.horizontal, 2).frame(height: 28)
                    .background(Color(nsColor: .controlBackgroundColor))
                }
                .frame(width: 220)

                Divider()

                Group {
                    if selected != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                TextField("Sample name", text: $editingName).textFieldStyle(.roundedBorder)
                                Picker("", selection: $editingScope) {
                                    ForEach(PipelineScope.allCases, id: \.self) { s in Text(s.displayName).tag(s) }
                                }
                                .labelsHidden().controlSize(.small).frame(width: 140)
                            }
                            TextEditor(text: $editingText)
                                .font(.body).scrollContentBackground(.hidden).padding(6)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                            HStack {
                                Text("\(editingText.count.formatted()) chars").font(.caption2).foregroundStyle(.tertiary)
                                Spacer()
                                if isDirty {
                                    Button("Discard") { loadEditing(selected) }.buttonStyle(.bordered).controlSize(.small)
                                    Button("Save") { saveEditing() }.buttonStyle(.borderedProminent).controlSize(.small)
                                }
                            }
                        }
                        .padding(16)
                    } else {
                        ContentUnavailableView("No Sample Selected",
                                               systemImage: "doc.text",
                                               description: Text("Select a sample to edit, or add a new one."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    if isDirty { saveEditing() }
                    if let id = selectedID { onSelect?(id) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 640, height: 440)
        .onAppear {
            if !didInit { selectedID = allSamples.first?.id; loadEditing(selected); didInit = true }
        }
        .onChange(of: selectedID) { _, _ in loadEditing(selected) }
    }

    private func loadEditing(_ s: PromptSample?) {
        editingName = s?.name ?? ""
        editingText = s?.sampleText ?? ""
        editingScope = s?.scope ?? .source
    }

    private func saveEditing() {
        guard let s = selected else { return }
        s.name = editingName; s.sampleText = editingText; s.scope = editingScope
        try? modelContext.save()
    }

    private func addSample() {
        guard allSamples.count < sampleLimit else { return }
        let s = PromptSample(name: "Sample \(allSamples.count + 1)",
                             scope: initialScope ?? .source,
                             sortOrder: allSamples.count)
        modelContext.insert(s)
        try? modelContext.save()
        selectedID = s.id
        loadEditing(s)
    }

    private func deleteSample(_ s: PromptSample) {
        if selectedID == s.id { selectedID = nil }
        modelContext.delete(s)
        try? modelContext.save()
        loadEditing(nil)
    }
}

// MARK: - Load from Action sheet

private struct LoadFromActionSheet: View {
    let onLoad: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]

    @State private var scopeFilter: PipelineScope? = nil
    @State private var selectedPipelineID: UUID? = nil
    @State private var selectedStepID: UUID? = nil

    private var filteredPipelines: [FormattingPipeline] {
        guard let f = scopeFilter else { return allPipelines }
        return allPipelines.filter { $0.scope == f }
    }
    private var selectedPipeline: FormattingPipeline? {
        filteredPipelines.first { $0.id == selectedPipelineID }
    }
    private var steps: [PipelineStep] { selectedPipeline?.sortedSteps ?? [] }
    private var selectedStep: PipelineStep? {
        steps.first { $0.id == selectedStepID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Load from Action").font(.headline)
                Spacer()
                Picker("", selection: $scopeFilter) {
                    Text("All Scopes").tag(nil as PipelineScope?)
                    ForEach(PipelineScope.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s as PipelineScope?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
                .onChange(of: scopeFilter) { _, _ in selectedPipelineID = nil; selectedStepID = nil }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ACTION")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    List(filteredPipelines, id: \.id, selection: $selectedPipelineID) { p in
                        Text(p.name).font(.callout).tag(p.id)
                    }
                    .listStyle(.sidebar)
                    .onChange(of: selectedPipelineID) { _, _ in selectedStepID = nil }
                }
                .frame(width: 200)

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    Text("STEP")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    if steps.isEmpty {
                        ContentUnavailableView("No Steps", systemImage: "list.bullet")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(steps, id: \.id, selection: $selectedStepID) { step in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.name).font(.callout)
                                Text(step.prompt.prefix(50) + (step.prompt.count > 50 ? "…" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .tag(step.id)
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(width: 220)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("PREVIEW")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    if let step = selectedStep {
                        ScrollView {
                            Text(step.prompt)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("Select a step to preview its prompt.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Load Prompt") {
                    if let step = selectedStep { onLoad(step.prompt); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedStep == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 700, height: 420)
    }
}

// MARK: - Load existing prompt sheet (Phase 25.4)

/// Internal (not private) so the Action step editor can reuse it to pick a saved prompt.
/// The current instruction, so the manager's "+" can pre-fill a new saved prompt from it.
struct SavedPromptSeed {
    var kind: PipelineStepKind
    var text: String
    var transformConfigJSON: String
    var extractConfigJSON: String
    var translateConfigJSON: String = ""
    var name: String
}

struct LoadExistingPromptSheet: View {
    /// When non-nil, prompts are pre-filtered to this scope tag (plus untagged "Any" prompts).
    var scopeFilter: PipelineScope?
    /// When set, the "+" button pre-fills a new prompt from the current instruction (else blank).
    var newSeed: SavedPromptSeed? = nil
    let onLoad: (SavedPrompt) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedPrompt.sortOrder) private var allPrompts: [SavedPrompt]

    @State private var selectedID: UUID?
    @State private var scopeFilterState: PipelineScope?
    @State private var didInit = false
    @State private var editingName: String = ""
    @State private var editingScope: PipelineScope? = nil
    @State private var editingText: String = ""
    @State private var editingTransform = TextTransformConfig()
    @State private var editingExtract = ExtractFieldsConfig()
    @State private var editingTranslate = TranslateConfig()

    /// Prompts tagged with a specific scope, in sort order.
    private func prompts(in scope: PipelineScope) -> [SavedPrompt] {
        allPrompts.filter { $0.scopeTag == scope }
    }
    /// Untagged, general-purpose ("Any") prompts — applicable to any scope.
    private var generalPrompts: [SavedPrompt] {
        allPrompts.filter { $0.scopeTag == nil }
    }
    private var selected: SavedPrompt? { allPrompts.first { $0.id == selectedID } }

    /// One selectable row — name only; the section header carries the scope.
    @ViewBuilder
    private func promptRow(_ p: SavedPrompt) -> some View {
        HStack(spacing: 6) {
            Text(p.name.isEmpty ? "Untitled" : p.name)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(Self.kindBadge(p.kind))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
        .tag(p.id)
        .contextMenu {
            Button("Duplicate") { duplicate(p) }
            Button("Delete", role: .destructive) { delete(p) }
        }
    }

    static func kindBadge(_ k: PipelineStepKind) -> String {
        switch k {
        case .aiPrompt:      return "Prompt"
        case .transform:     return "Transform"
        case .extractFields: return "Extract"
        case .translate:     return "Translate"
        }
    }

    /// A readable preview of a saved item — its prompt text, or a config summary.
    static func previewText(_ p: SavedPrompt) -> String {
        switch p.kind {
        case .aiPrompt:
            return p.text
        case .transform:
            let c = p.transformConfig
            if c.type == .findReplace {
                return "Find & Replace\nFind:    \(c.find)\nReplace: \(c.replace)\nRegex: \(c.useRegex ? "on" : "off")"
            }
            return c.type.displayName
        case .extractFields:
            let names = p.extractConfig.fields.map(\.name).filter { !$0.isEmpty }
            return "Extract Fields: " + (names.isEmpty ? "(none)" : names.joined(separator: ", "))
        case .translate:
            return TranslationCatalog.shared.summary(for: p.translateConfig)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Saved Instructions").font(.headline)
                Spacer()
                Picker("", selection: $scopeFilterState) {
                    Text("All Scopes").tag(nil as PipelineScope?)
                    ForEach(PipelineScope.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s as PipelineScope?)
                    }
                }
                .pickerStyle(.menu).labelsHidden().controlSize(.small).frame(width: 130)
            }
            .padding(.horizontal, 20).padding(.vertical, 14).background(.bar)

            Divider()

            HStack(spacing: 0) {
                // Option 3: a chosen stage shows its own prompts, then a "General (Any)"
                // section of untagged prompts below — universal prompts are never hidden,
                // and there's no extra toggle to learn.
                VStack(spacing: 0) {
                List(selection: $selectedID) {
                    if let f = scopeFilterState {
                        let scoped = prompts(in: f)
                        if !scoped.isEmpty {
                            Section(f.displayName) {
                                ForEach(scoped, id: \.id) { promptRow($0) }
                            }
                        }
                        if !generalPrompts.isEmpty {
                            Section("General (Any)") {
                                ForEach(generalPrompts, id: \.id) { promptRow($0) }
                            }
                        }
                    } else {
                        // All Scopes: one section per stage, general-purpose last.
                        ForEach(PipelineScope.allCases, id: \.self) { s in
                            let group = prompts(in: s)
                            if !group.isEmpty {
                                Section(s.displayName) {
                                    ForEach(group, id: \.id) { promptRow($0) }
                                }
                            }
                        }
                        if !generalPrompts.isEmpty {
                            Section("General (Any)") {
                                ForEach(generalPrompts, id: \.id) { promptRow($0) }
                            }
                        }
                    }
                }
                .listStyle(.inset)

                Divider()

                HStack(spacing: 0) {
                    Button { addBlankPrompt() } label: { Image(systemName: "plus").frame(width: 28, height: 22) }
                        .buttonStyle(.borderless)
                        .help(newSeed != nil ? "Add — pre-filled with the current instruction" : "Add a blank prompt")
                    Divider().frame(height: 14)
                    Button { if let p = selected { delete(p) } } label: { Image(systemName: "minus").frame(width: 28, height: 22) }
                        .buttonStyle(.borderless).disabled(selected == nil).help("Delete selected prompt")
                    Divider().frame(height: 14)
                    Button { if let p = selected { duplicate(p) } } label: { Image(systemName: "doc.on.doc").frame(width: 28, height: 22) }
                        .buttonStyle(.borderless).disabled(selected == nil).help("Duplicate selected prompt")
                    Spacer()
                }
                .padding(.horizontal, 2).frame(height: 28)
                .background(Color(nsColor: .controlBackgroundColor))
                }
                .frame(width: 220)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    if let p = selected {
                        HStack(spacing: 8) {
                            TextField("Name", text: $editingName).textFieldStyle(.roundedBorder)
                            Picker("", selection: $editingScope) {
                                Text("Any").tag(nil as PipelineScope?)
                                ForEach(PipelineScope.allCases, id: \.self) { s in
                                    Text(s.displayName).tag(s as PipelineScope?)
                                }
                            }
                            .labelsHidden().controlSize(.small).frame(width: 130)
                            Text(Self.kindBadge(p.kind))
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }

                        Group {
                            switch p.kind {
                            case .aiPrompt:
                                TextEditor(text: $editingText)
                                    .font(.callout).scrollContentBackground(.hidden).padding(6)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                                    .overlay(alignment: .bottomTrailing) { DictateButton().padding(8) }
                            case .transform:
                                ScrollView { TransformConfigEditor(config: $editingTransform).padding(6) }
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            case .extractFields:
                                ScrollView { ExtractFieldsEditor(config: $editingExtract).padding(6) }
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            case .translate:
                                ScrollView { TranslateConfigEditor(config: $editingTranslate).padding(6) }
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        HStack {
                            Spacer()
                            if isDirty {
                                Button("Discard") { loadEditing(p) }.buttonStyle(.bordered).controlSize(.small)
                                Button("Save") { saveEditing(p) }.buttonStyle(.borderedProminent).controlSize(.small)
                                    .disabled(editingName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    } else {
                        ContentUnavailableView("No Prompt Selected",
                                               systemImage: "text.badge.plus",
                                               description: Text("Select a prompt to edit it, or add one with +."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Button("Load") { if let p = selected { onLoad(p); dismiss() } }
                    .buttonStyle(.borderedProminent).disabled(selected == nil)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 620, height: 460)
        .onAppear { if !didInit { scopeFilterState = scopeFilter; didInit = true }; loadEditing(selected) }
        .onChange(of: selectedID) { _, _ in loadEditing(selected) }
    }

    private var isDirty: Bool {
        guard let p = selected else { return false }
        if editingName != p.name { return true }
        if editingScope != p.scopeTag { return true }
        switch p.kind {
        case .aiPrompt:      return editingText != p.text
        case .transform:     return editingTransform != p.transformConfig
        case .extractFields: return editingExtract != p.extractConfig
        case .translate:     return editingTranslate != p.translateConfig
        }
    }

    private func loadEditing(_ p: SavedPrompt?) {
        editingName = p?.name ?? ""
        editingScope = p?.scopeTag
        editingText = p?.text ?? ""
        editingTransform = p?.transformConfig ?? TextTransformConfig()
        editingExtract = p?.extractConfig ?? ExtractFieldsConfig()
        editingTranslate = p?.translateConfig ?? TranslateConfig()
    }

    private func saveEditing(_ p: SavedPrompt) {
        p.name = editingName.trimmingCharacters(in: .whitespaces)
        p.scopeTag = editingScope
        switch p.kind {
        case .aiPrompt:      p.text = editingText
        case .transform:     p.transformConfig = editingTransform
        case .extractFields: p.extractConfig = editingExtract
        case .translate:     p.translateConfig = editingTranslate
        }
        try? modelContext.save()
    }

    private func addBlankPrompt() {
        let p: SavedPrompt
        if let s = newSeed {
            p = SavedPrompt(name: s.name.isEmpty ? "New Prompt" : s.name,
                            text: s.text, sortOrder: allPrompts.count,
                            kind: s.kind,
                            transformConfigJSON: s.transformConfigJSON,
                            extractConfigJSON: s.extractConfigJSON,
                            translateConfigJSON: s.translateConfigJSON)
        } else {
            p = SavedPrompt(name: "New Prompt", text: "", sortOrder: allPrompts.count)
        }
        modelContext.insert(p)
        try? modelContext.save()
        selectedID = p.id
    }

    private func duplicate(_ p: SavedPrompt) {
        let copy = SavedPrompt(name: p.name + " Copy", text: p.text,
                               scopeTag: p.scopeTag, sortOrder: allPrompts.count,
                               kind: p.kind,
                               transformConfigJSON: p.transformConfigJSON,
                               extractConfigJSON: p.extractConfigJSON,
                               translateConfigJSON: p.translateConfigJSON)
        modelContext.insert(copy)
        try? modelContext.save()
        selectedID = copy.id
    }

    private func delete(_ p: SavedPrompt) {
        if selectedID == p.id { selectedID = nil }
        modelContext.delete(p)
        try? modelContext.save()
    }
}

// MARK: - Save prompt to library sheet (Phase 25.2)

/// Save the given prompt text to the SavedPrompt library under a new name. Reused by the Prompt
/// Builder and by the wizard's inline improve panel (so a step's prompt can be banked for reuse).
struct SavePromptToLibrarySheet: View {
    let promptText: String
    var initialScope: PipelineScope?
    var nextSortOrder: Int
    /// The instruction kind being saved. Defaults to `.aiPrompt` so existing callers (the wizard
    /// inline-improve panel) keep working unchanged.
    var kind: PipelineStepKind = .aiPrompt
    var transformConfigJSON: String = ""
    var extractConfigJSON: String = ""
    var translateConfigJSON: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name: String = ""
    @State private var scope: PipelineScope? = nil
    @State private var didInit = false

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A readable preview of what's being saved — the prompt for AI, a config summary otherwise.
    private var previewText: String {
        switch kind {
        case .aiPrompt:
            return promptText
        case .transform:
            let c = TextTransformConfig.decode(transformConfigJSON)
            if c.type == .findReplace {
                return "Find & Replace\nFind:    \(c.find)\nReplace: \(c.replace)\nRegex: \(c.useRegex ? "on" : "off") · Case-sensitive: \(c.caseSensitive ? "yes" : "no")"
            }
            return c.type.displayName
        case .extractFields:
            let c = ExtractFieldsConfig.decode(extractConfigJSON)
            let names = c.fields.map(\.name).filter { !$0.isEmpty }
            return "Extract Fields: " + (names.isEmpty ? "(none)" : names.joined(separator: ", "))
        case .translate:
            return TranslationCatalog.shared.summary(for: TranslateConfig.decode(translateConfigJSON))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Save to Library").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14).background(.bar)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("Name") {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 260)
                }
                LabeledContent("Scope tag") {
                    Picker("", selection: $scope) {
                        Text("Any").tag(nil as PipelineScope?)
                        ForEach(PipelineScope.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s as PipelineScope?)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 160)
                }
                Text("Scope is an optional filter tag — leave it \"Any\" if the instruction applies broadly.")
                    .font(.caption).foregroundStyle(.secondary)

                Text("Preview").font(.caption.bold()).foregroundStyle(.secondary)
                ScrollView {
                    Text(previewText)
                        .font(kind == .aiPrompt ? .callout : .system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(20)

            Spacer()
            Divider()

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(!canSave)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 480, height: 420)
        .onAppear { if !didInit { scope = initialScope; didInit = true } }
    }

    private func save() {
        let item = SavedPrompt(name: name.trimmingCharacters(in: .whitespaces),
                               text: kind == .aiPrompt ? promptText : "",
                               scopeTag: scope,
                               sortOrder: nextSortOrder,
                               kind: kind,
                               transformConfigJSON: transformConfigJSON,
                               extractConfigJSON: extractConfigJSON,
                               translateConfigJSON: translateConfigJSON)
        modelContext.insert(item)
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Markdown-aware result text

private struct PromptBuilderResultText: View {
    let text: String
    init(_ text: String) { self.text = text }

    private var attributedString: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        Text(attributedString)
    }
}

// MARK: - Reusable instruction editors

/// Editor for a deterministic transform's configuration. Used by the Instruction Lab; the
/// Action step row (`PipelineStepRow`) has an equivalent inline editor.
struct TransformConfigEditor: View {
    @Binding var config: TextTransformConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Transform", selection: $config.type) {
                ForEach(TextTransformType.allCases, id: \.self) { t in
                    Label(t.displayName, systemImage: t.icon).tag(t)
                }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()

            Text(config.type.summary)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch config.type {
            case .findReplace:   findReplace
            case .delimiter:     delimiter
            case .whitespace:    whitespace
            case .caseTransform: caseTransform
            case .lineOps:       lineOps
            case .homoglyph:     EmptyView()
            }
        }
    }

    private var findReplace: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Find").font(.caption).foregroundStyle(.secondary)
                TextField(config.useRegex ? "pattern" : "text to find", text: $config.find)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Replace").font(.caption).foregroundStyle(.secondary)
                TextField("replacement", text: $config.replace)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            }
            HStack(spacing: 16) {
                Toggle("Regular expression", isOn: $config.useRegex).toggleStyle(.checkbox)
                Toggle("Case sensitive", isOn: $config.caseSensitive).toggleStyle(.checkbox)
            }
            .font(.caption)
        }
    }

    private var delimiter: some View {
        Picker("Conversion", selection: $config.delimiterPreset) {
            ForEach(DelimiterPreset.allCases, id: \.self) { p in Text(p.displayName).tag(p) }
        }
        .pickerStyle(.menu).labelsHidden()
    }

    private var whitespace: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Normalize line endings", isOn: $config.normalizeNewlines).toggleStyle(.checkbox)
            Toggle("Trim spaces at the start and end of each line", isOn: $config.trimEachLine).toggleStyle(.checkbox)
            Toggle("Remove trailing spaces", isOn: $config.trimTrailingSpaces).toggleStyle(.checkbox).disabled(config.trimEachLine)
            Toggle("Collapse repeated spaces into one", isOn: $config.collapseSpaces).toggleStyle(.checkbox)
            Toggle("Collapse multiple blank lines into one", isOn: $config.collapseBlankLines).toggleStyle(.checkbox)
        }
        .font(.caption)
    }

    private var caseTransform: some View {
        Picker("Case", selection: $config.caseMode) {
            ForEach(LetterCaseMode.allCases, id: \.self) { m in Text(m.displayName).tag(m) }
        }
        .pickerStyle(.segmented).labelsHidden()
    }

    private var lineOps: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Remove empty lines", isOn: $config.removeEmptyLines).toggleStyle(.checkbox)
            Toggle("Remove duplicate lines", isOn: $config.dedupeLines).toggleStyle(.checkbox)
            Toggle("Sort lines", isOn: $config.sortLines).toggleStyle(.checkbox)
            Toggle("Sort descending", isOn: $config.sortDescending).toggleStyle(.checkbox)
                .disabled(!config.sortLines).padding(.leading, 16)
            VStack(alignment: .leading, spacing: 4) {
                Text("Header row").font(.caption).foregroundStyle(.secondary)
                TextField("optional — type \\t between columns", text: $config.headerText)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            }
            .padding(.top, 2)
        }
        .font(.caption)
    }
}

/// Editor for an Extract-Fields instruction. Mirrors the Action step row's inline editor.
struct ExtractFieldsEditor: View {
    @Binding var config: ExtractFieldsConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The AI fills these fields, then they're combined deterministically — reliable structured output instead of asking a prompt for delimited text.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            ForEach($config.fields) { $field in
                HStack(spacing: 6) {
                    TextField("Field name", text: $field.name).textFieldStyle(.roundedBorder).frame(width: 130)
                    Picker("", selection: $field.type) {
                        ForEach(ExtractFieldType.allCases, id: \.self) { t in Text(t.displayName).tag(t) }
                    }
                    .labelsHidden().fixedSize()
                    TextField("description (optional)", text: $field.fieldDescription).textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        config.fields.removeAll { $0.id == field.id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove this field")
                }
            }

            Button { config.fields.append(ExtractField()) } label: {
                Label("Add Field", systemImage: "plus").font(.caption)
            }
            .buttonStyle(.borderless)

            Divider()

            HStack(spacing: 8) {
                Text("Combine with:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $config.delimiter) {
                    ForEach(ExtractDelimiter.allCases, id: \.self) { d in Text(d.displayName).tag(d) }
                }
                .labelsHidden().fixedSize().disabled(!config.template.isEmpty)
                Spacer()
            }

            TextField("Optional template, e.g. {Date}\\t{Payee}\\t{Total}", text: $config.template)
                .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                .help("If set, overrides the delimiter. Use {Field Name} placeholders; \\t = Tab, \\n = newline.")
        }
    }
}

// MARK: - Dictation (app-wide voice input into any multiline field, Phase 28)

/// Drives live dictation into the *currently focused* text view. Reuses `SpeechCaptureService`
/// (its `finalSegments` stream is built for real-time insertion) and inserts each recognised
/// phrase at the caret via the responder chain — so it works with existing SwiftUI `TextEditor`s
/// without replacing them.
@MainActor
final class DictationEngine: ObservableObject {
    @Published var isRecording = false
    @Published var errorText: String?

    private let service = SpeechCaptureService()
    private var task: Task<Void, Never>?
    private weak var target: NSTextView?

    // The range currently holding the live (uncommitted) volatile preview at the caret.
    private var volatileStart = 0
    private var volatileLength = 0

    func toggle() { isRecording ? stop() : start() }

    private func start() {
        // The field being edited is the window's first responder. Capture it as the target.
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable else {
            NSSound.beep()
            errorText = "Click into a text field first, then dictate."
            return
        }
        target = tv
        // Seed the volatile region with the current selection so the first dictated words
        // *replace* selected text (rather than inserting before it).
        let sel = tv.selectedRange()
        volatileStart = sel.location
        volatileLength = sel.length
        errorText = nil
        isRecording = true
        task = Task { @MainActor in
            do {
                let streams = try await service.startCapture()
                // Consume both streams: volatileText drives the live word-by-word preview,
                // finalSegments commit each phrase. Both run on the main actor.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor [weak self] in
                        for await text in streams.volatileText { self?.showVolatile(text) }
                    }
                    group.addTask { @MainActor [weak self] in
                        for await segment in streams.finalSegments { self?.commit(segment) }
                    }
                }
            } catch {
                errorText = error.localizedDescription
            }
            isRecording = false
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        // Do NOT cancel — stopCapture() finalizes the last phrase through the streams, which
        // then finish on their own. Cancelling would drop that phrase.
        Task { _ = await service.stopCapture() }
    }

    /// Live preview: replace the current volatile region at the caret with the latest in-progress text.
    private func showVolatile(_ text: String) {
        guard let tv = target, tv.window != nil else { return }
        let range = safeRange(volatileStart, volatileLength, in: tv)
        tv.insertText(text, replacementRange: range)
        volatileStart = range.location
        volatileLength = (text as NSString).length
    }

    /// Commit a finalized phrase (replacing its live preview) and advance the caret past it.
    private func commit(_ segment: String) {
        guard let tv = target, tv.window != nil else { return }
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? "" : trimmed + " "
        let range = safeRange(volatileStart, volatileLength, in: tv)
        tv.insertText(text, replacementRange: range)
        volatileStart = range.location + (text as NSString).length
        volatileLength = 0
    }

    private func safeRange(_ loc: Int, _ len: Int, in tv: NSTextView) -> NSRange {
        let total = (tv.string as NSString).length
        let l = max(0, min(loc, total))
        let n = max(0, min(len, total - l))
        return NSRange(location: l, length: n)
    }
}

/// Standard app-wide dictate control: **green mic = ready**, **red mic = recording** (tap to stop).
/// Place next to (or overlaid on) any multiline field; it dictates into whichever field is focused.
struct DictateButton: View {
    @StateObject private var engine = DictationEngine()

    var body: some View {
        Button {
            engine.toggle()
        } label: {
            Image(systemName: engine.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(engine.isRecording ? Color.red : Color.green)
                .padding(5)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(engine.isRecording
              ? "Stop dictation"
              : "Dictate — inserts speech at the cursor of the focused field")
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    return PromptBuilderView()
        .modelContainer(c)
}
