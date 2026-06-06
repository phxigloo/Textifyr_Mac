import SwiftUI
import SwiftData
import FoundationModels
import TextifyrModels
import TextifyrServices

// MARK: - Selection type

private enum SampleSelection: Hashable {
    case scratchpad
    case saved(UUID)
}

// MARK: - Main view

struct PromptBuilderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \PromptSample.sortOrder) private var allSamples: [PromptSample]

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
    @State private var chatMessages: [PromptChatMessage] = []
    @State private var chatInput: String = ""
    @State private var isChatting = false
    @State private var chatTask: Task<Void, Never>? = nil
    @State private var chatSession: LanguageModelSession? = nil
    @State private var chatNeedsContextRefresh = false

    @State private var editingName: String = ""
    @State private var editingText: String = ""
    @State private var editingScope: PipelineScope = .source

    @State private var showingLoadSheet = false
    @State private var showingSaveSheet = false

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

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                HStack(spacing: 0) {
                    samplesListPanel
                    Divider()
                    sampleWorkArea
                    Divider()
                    promptPanel
                }
                .frame(minWidth: 620)

                if showImprovePanel {
                    improvePanel
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                runToolbarContent
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 1000, minHeight: 580)
        .onAppear { restoreDraft() }
        .onChange(of: promptText)     { _, t in UserDefaults.standard.set(t, forKey: Self.draftPromptKey) }
        .onChange(of: scratchpadText) { _, t in UserDefaults.standard.set(t, forKey: Self.draftScratchpadKey) }
        .onChange(of: testResult) { _, _ in
            if showImprovePanel { resetChat() } else { chatNeedsContextRefresh = true }
        }
        .onChange(of: showImprovePanel) { _, isVisible in
            if isVisible && chatNeedsContextRefresh { resetChat() }
        }
        .onChange(of: scopeFilter) { _, _ in
            if case .saved = sampleSelection { sampleSelection = .scratchpad }
            testResult = nil; testError = nil
        }
        .onChange(of: sampleSelection) { _, newSelection in
            testResult = nil; testError = nil
            if case .saved(let id) = newSelection,
               let sample = allSamples.first(where: { $0.id == id }) {
                editingName  = sample.name
                editingText  = sample.sampleText
                editingScope = sample.scope
            }
        }
        .sheet(isPresented: $showingLoadSheet) {
            LoadFromActionSheet { loaded in promptText = loaded }
        }
        .sheet(isPresented: $showingSaveSheet) {
            SaveToPipelineSheet(promptText: promptText)
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
            Button { runPrompt() } label: {
                Label("Run Prompt", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(promptText.isEmpty || activeText.isEmpty)
            .help(runHelpText)
        }
    }

    private var runHelpText: String {
        if promptText.isEmpty  { return "Enter a prompt first" }
        if activeText.isEmpty  { return "Enter or select sample text first" }
        return ""
    }

    // MARK: - Samples list panel (left, ~200 pt)

    private var samplesListPanel: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Samples").font(.title3.bold())
                    Spacer()
                }
                .frame(height: 44)
                .padding(.horizontal, 12)

                Divider()

                HStack {
                    Picker("Scope", selection: $scopeFilter) {
                        Text("All Scopes").tag(nil as PipelineScope?)
                        ForEach(PipelineScope.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s as PipelineScope?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    Spacer()
                }
                .frame(height: 30)
                .padding(.horizontal, 12)
            }
            .background(.bar)

            Divider()

            List(selection: $sampleSelection) {
                Label("Scratchpad", systemImage: "pencil.and.scribble")
                    .font(.callout)
                    .tag(SampleSelection.scratchpad)

                if !filteredSamples.isEmpty {
                    Section("Saved") {
                        ForEach(filteredSamples, id: \.id) { sample in
                            SampleRowView(sample: sample)
                                .tag(SampleSelection.saved(sample.id))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { deleteSample(sample) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button("Delete", role: .destructive) { deleteSample(sample) }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 0) {
                Button {
                    addSample()
                } label: {
                    Image(systemName: "plus").frame(width: 28, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(allSamples.count >= sampleLimit)
                .help("Add sample (\(sampleLimit) max)")

                Divider().frame(height: 14)

                Button {
                    if let s = selectedSample { deleteSample(s) }
                } label: {
                    Image(systemName: "minus").frame(width: 28, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(selectedSample == nil)
                .help("Delete selected sample")

                Spacer()
            }
            .padding(.horizontal, 2)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 200)
    }

    // MARK: - Sample work area (middle, flex)

    @ViewBuilder
    private var sampleWorkArea: some View {
        switch sampleSelection {
        case .scratchpad:
            scratchpadWorkArea
        case .saved:
            if let sample = selectedSample {
                savedSampleWorkArea(sample)
            } else {
                emptySelectionView
            }
        case nil:
            emptySelectionView
        }
    }

    private var scratchpadWorkArea: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scratchpad").font(.title3.bold())
                Text("· not saved").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !scratchpadText.isEmpty {
                    Button("Clear") { scratchpadText = "" }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Temporary — paste or type text to test your prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $scratchpadText)
                        .font(.body)
                        .frame(minHeight: 130, maxHeight: 220)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    HStack {
                        Spacer()
                        Text("\(scratchpadText.count.formatted()) chars")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if let err = testError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    resultView
                }
                .padding(16)
            }
        }
    }

    private func savedSampleWorkArea(_ sample: PromptSample) -> some View {
        VStack(spacing: 0) {
            // Fixed header: editable name + scope picker
            HStack(spacing: 8) {
                TextField("Untitled Sample", text: $editingName)
                    .font(.title3.bold())
                    .textFieldStyle(.plain)
                Spacer()
                Picker("Scope", selection: $editingScope) {
                    ForEach(PipelineScope.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .background(.bar)

            // Save / Discard bar — only visible when there are unsaved changes
            if sampleIsDirty {
                Divider()
                HStack(spacing: 8) {
                    Button("Discard") {
                        editingName  = sample.name
                        editingText  = sample.sampleText
                        editingScope = sample.scope
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Button("Save") {
                        sample.name      = editingName
                        sample.sampleText = editingText
                        sample.scope     = editingScope
                        try? modelContext.save()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextEditor(text: $editingText)
                        .font(.body)
                        .frame(minHeight: 130, maxHeight: 220)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    HStack {
                        Spacer()
                        Text("\(editingText.count.formatted()) chars")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if let err = testError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    resultView
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var resultView: some View {
        if let result = testResult {
            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("Result")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            PromptBuilderResultText(result)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var emptySelectionView: some View {
        ContentUnavailableView(
            "No Sample Selected",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Select a sample from the list, or use Scratchpad to test without saving.")
        )
    }

    // MARK: - Prompt panel (right, fixed 320 pt)

    private var promptPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Prompt", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showImprovePanel.toggle()
                    }
                } label: {
                    Image(systemName: "wand.and.sparkles")
                        .foregroundStyle(showImprovePanel ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(promptText.isEmpty)
                .help(showImprovePanel ? "Hide AI Improvement" : "Improve prompt with AI")
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $promptText)
                            .font(.body)
                            .frame(minHeight: 200)
                            .scrollContentBackground(.hidden)
                            .padding(6)

                        if promptText.isEmpty {
                            Text("Enter your prompt here…")
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

                    HStack {
                        Spacer()
                        Text("\(promptText.count) / \(AppConstants.maxPromptCharacters) chars")
                            .font(.caption2)
                            .foregroundStyle(promptText.count > AppConstants.maxPromptCharacters
                                ? AnyShapeStyle(.red)
                                : AnyShapeStyle(.tertiary))
                    }
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Load from Action…") { showingLoadSheet = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Button("Clear") { promptText = "" }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(promptText.isEmpty)
                Button("Save to Action…") { showingSaveSheet = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(promptText.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 320)
    }

    // MARK: - AI Improvement chat panel (slide in from right)

    private var improvePanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("AI Improvement", systemImage: "wand.and.sparkles")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showImprovePanel = false }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Hide AI Improvement")
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .background(.bar)

            // Context badge
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.caption2).foregroundStyle(.secondary)
                Text(chatPromptBadge)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Image(systemName: testResult != nil ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(testResult != nil ? Color.green : Color.orange)
                Text(testResult != nil ? "Result ready" : "No result")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Messages
            chatMessagesView

            Divider()

            // Input
            chatInputArea
        }
    }

    private var chatPromptBadge: String {
        guard !promptText.isEmpty else { return "No prompt entered" }
        return String(promptText.prefix(40)) + (promptText.count > 40 ? "…" : "")
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
                            Text("Ask why your prompt produced this output, request improvements, or describe what you wanted instead.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .padding(.horizontal, 16)
                    }

                    ForEach(chatMessages) { msg in
                        PromptChatMessageRow(message: msg) { suggested in
                            promptText = suggested
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

    private func addSample() {
        guard allSamples.count < sampleLimit else { return }
        let scope  = scopeFilter ?? .source
        let sample = PromptSample(
            name: "Sample \(allSamples.count + 1)",
            scope: scope,
            sortOrder: allSamples.count
        )
        modelContext.insert(sample)
        try? modelContext.save()
        editingName  = sample.name
        editingText  = sample.sampleText
        editingScope = sample.scope
        sampleSelection = .saved(sample.id)
    }

    private func deleteSample(_ sample: PromptSample) {
        if case .saved(let id) = sampleSelection, id == sample.id {
            sampleSelection = .scratchpad
        }
        modelContext.delete(sample)
        try? modelContext.save()
    }

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

    private func makeSession() -> LanguageModelSession {
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

        return LanguageModelSession(instructions: instructions)
    }

    private func sendChatMessage() {
        let trimmed = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isChatting else { return }

        guard SystemLanguageModel.default.isAvailable else {
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
                    chatMessages.append(PromptChatMessage(role: .assistant, rawContent: response.content))
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
        promptText     = UserDefaults.standard.string(forKey: Self.draftPromptKey) ?? ""
        scratchpadText = UserDefaults.standard.string(forKey: Self.draftScratchpadKey) ?? ""
    }
}

// MARK: - Chat message model

private struct PromptChatMessage: Identifiable {
    let id = UUID()
    enum Role { case user, assistant }
    let role: Role
    let displayContent: String
    let suggestedPrompt: String?

    init(role: Role, rawContent: String) {
        self.role = role
        let (display, suggested) = Self.parse(rawContent)
        self.displayContent = display
        self.suggestedPrompt = suggested
    }

    static func parse(_ content: String) -> (display: String, prompt: String?) {
        let marker = "SUGGESTED PROMPT:"
        guard let range = content.range(of: marker, options: .caseInsensitive) else {
            return (content.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let display = String(content[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt  = String(content[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (display.isEmpty ? content : display, prompt.isEmpty ? nil : prompt)
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
                        Label("Use as Prompt", systemImage: "arrow.up.right.circle")
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
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
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
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
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

// MARK: - Save to Pipeline sheet

private struct SaveToPipelineSheet: View {
    let promptText: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]

    enum SaveMode: String, CaseIterable {
        case updateStep   = "Update Existing Step"
        case addStep      = "Add to Action"
        case newPipeline  = "New Action"
    }

    @State private var scope: PipelineScope = .source
    @State private var saveMode: SaveMode = .addStep
    @State private var selectedPipelineID: UUID? = nil
    @State private var selectedStepID: UUID? = nil
    @State private var newPipelineName: String = ""
    @State private var newStepName: String = "Step 1"

    private var scopedPipelines: [FormattingPipeline] {
        allPipelines.filter { $0.scope == scope }
    }
    private var selectedPipeline: FormattingPipeline? {
        allPipelines.first { $0.id == selectedPipelineID }
    }
    private var steps: [PipelineStep] { selectedPipeline?.sortedSteps ?? [] }
    private var selectedStep: PipelineStep? {
        steps.first { $0.id == selectedStepID }
    }
    private var canSave: Bool {
        switch saveMode {
        case .updateStep:  return selectedStep != nil
        case .addStep:     return selectedPipeline != nil && !newStepName.trimmingCharacters(in: .whitespaces).isEmpty
        case .newPipeline: return !newPipelineName.trimmingCharacters(in: .whitespaces).isEmpty
                                  && !newStepName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Save to Action").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("Scope") {
                    Picker("", selection: $scope) {
                        ForEach(PipelineScope.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: scope) { _, _ in selectedPipelineID = nil; selectedStepID = nil }
                }

                Picker("", selection: $saveMode) {
                    ForEach(SaveMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: saveMode) { _, _ in
                    selectedPipelineID = nil
                    selectedStepID     = nil
                }

                Group {
                    switch saveMode {
                    case .updateStep:  updateStepBody
                    case .addStep:     addStepBody
                    case .newPipeline: newPipelineBody
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)

            Spacer()
            Divider()

            HStack {
                Text(saveModeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save") { performSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 460)
    }

    @ViewBuilder
    private var updateStepBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select the action and step whose prompt to replace.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action (\(scope.displayName))")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    List(scopedPipelines, id: \.id, selection: $selectedPipelineID) { p in
                        Text(p.name).tag(p.id)
                    }
                    .listStyle(.bordered)
                    .onChange(of: selectedPipelineID) { _, _ in selectedStepID = nil }
                }
                .frame(width: 200, height: 160)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Step")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    List(steps, id: \.id, selection: $selectedStepID) { step in
                        Text(step.name).tag(step.id)
                    }
                    .listStyle(.bordered)
                }
                .frame(width: 220, height: 160)
            }
        }
    }

    @ViewBuilder
    private var addStepBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appends a new step with this prompt to the selected action.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Action (\(scope.displayName))")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                List(scopedPipelines, id: \.id, selection: $selectedPipelineID) { p in
                    Text(p.name).tag(p.id)
                }
                .listStyle(.bordered)
                .frame(height: 130)
            }

            LabeledContent("Step Name") {
                TextField("e.g. Clean Up Filler Words", text: $newStepName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private var newPipelineBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Creates a new \(scope.displayName) action with this prompt as its first step.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Action Name") {
                TextField("e.g. Transcript Cleanup", text: $newPipelineName)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Step Name") {
                TextField("e.g. Remove Filler Words", text: $newStepName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var saveModeHint: String {
        switch saveMode {
        case .updateStep:  return "Replaces the selected step's prompt in place."
        case .addStep:     return "Appends a new step; existing steps are unchanged."
        case .newPipeline: return "Creates an action scoped to \(scope.displayName)."
        }
    }

    private func performSave() {
        switch saveMode {
        case .updateStep:
            guard let step = selectedStep else { return }
            step.prompt = promptText
            try? modelContext.save()

        case .addStep:
            guard let pipeline = selectedPipeline else { return }
            let order = (pipeline.steps ?? []).count
            let step  = PipelineStep(name: newStepName.trimmingCharacters(in: .whitespaces),
                                     prompt: promptText,
                                     sortOrder: order)
            modelContext.insert(step)
            step.pipeline  = pipeline
            pipeline.steps = (pipeline.steps ?? []) + [step]
            try? modelContext.save()

        case .newPipeline:
            let pipeline = FormattingPipeline(
                name: newPipelineName.trimmingCharacters(in: .whitespaces),
                mode: .sequential,
                isBuiltIn: false
            )
            pipeline.scope = scope
            modelContext.insert(pipeline)
            let step = PipelineStep(name: newStepName.trimmingCharacters(in: .whitespaces),
                                    prompt: promptText,
                                    sortOrder: 0)
            modelContext.insert(step)
            step.pipeline  = pipeline
            pipeline.steps = [step]
            try? modelContext.save()
        }
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

#Preview { @MainActor in
    let c = makePreviewContainer()
    return PromptBuilderView()
        .modelContainer(c)
}
