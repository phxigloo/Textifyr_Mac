import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

struct SessionChatView: View {
    @StateObject private var viewModel: SessionChatViewModel
    var onReplaceTranscript: ((String) -> Void)?
    var onAddToTranscript: ((String) -> Void)?

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "source" },
           sort: \FormattingPipeline.name) private var sourcePipelines: [FormattingPipeline]

    @State private var selectedPipeline: FormattingPipeline?
    @State private var showReplaceConfirmation = false

    private var pipelinePrompts: [(name: String, prompt: String)] {
        sourcePipelines.compactMap { pipeline in
            guard let firstStep = pipeline.sortedSteps.first else { return nil }
            return (name: pipeline.name, prompt: firstStep.prompt)
        }
    }

    init(session: SourceSession, context: ModelContext,
         onReplaceTranscript: ((String) -> Void)? = nil,
         onAddToTranscript: ((String) -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: SessionChatViewModel(session: session, context: context))
        self.onReplaceTranscript = onReplaceTranscript
        self.onAddToTranscript   = onAddToTranscript
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pipeline runner bar
            if !sourcePipelines.isEmpty {
                pipelineBar
                Divider()
            }

            // Chat scroll area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { msg in
                            ChatBubble(
                                message: msg,
                                onReplaceTranscript: msg.role == .assistant ? onReplaceTranscript : nil,
                                onAddToTranscript:   msg.role == .assistant ? onAddToTranscript   : nil
                            )
                            .id(msg.id)
                        }

                        // Pipeline result bubble
                        if viewModel.isRunningPipeline {
                            ThinkingIndicator(label: viewModel.pipelineStep.isEmpty
                                ? "Pipeline running…"
                                : viewModel.pipelineStep)
                                .id("pipeline-running")
                        } else if let output = viewModel.pipelineOutput {
                            PipelineResultBubble(
                                text: output,
                                onReplace: { showReplaceConfirmation = true },
                                onDismiss: { viewModel.dismissPipelineOutput() }
                            )
                            .id("pipeline-result")
                        }

                        // Chat thinking indicator
                        if viewModel.isResponding && !viewModel.isRunningPipeline {
                            if viewModel.streamingResponse.isEmpty {
                                ThinkingIndicator(label: "Apple Intelligence is thinking…")
                                    .id("thinking")
                            } else {
                                ChatBubble(streamingText: viewModel.streamingResponse)
                                    .id("streaming")
                            }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    proxy.scrollTo(viewModel.messages.last?.id ?? UUID(), anchor: .bottom)
                }
                .onChange(of: viewModel.streamingResponse) { _, _ in
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
                .onChange(of: viewModel.isRunningPipeline) { _, running in
                    if running { proxy.scrollTo("pipeline-running", anchor: .bottom) }
                }
                .onChange(of: viewModel.pipelineOutput) { _, out in
                    if out != nil { proxy.scrollTo("pipeline-result", anchor: .bottom) }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            Divider()

            ChatInputBar(
                isResponding: viewModel.isResponding || viewModel.isRunningPipeline,
                onSend: { text in Task { await viewModel.send(text) } },
                onCancel: { viewModel.cancelResponse() },
                pipelinePrompts: pipelinePrompts
            )
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    viewModel.clearHistory()
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
                .help("Clear conversation history and start fresh")
                .disabled(viewModel.messages.isEmpty && !viewModel.isResponding)
            }
        }
        .confirmationDialog(
            "Replace Transcript",
            isPresented: $showReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                if let output = viewModel.pipelineOutput {
                    viewModel.replaceTranscript(with: output)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The original transcript will be permanently replaced with the pipeline output. This cannot be undone.")
        }
        .onAppear {
            if selectedPipeline == nil { selectedPipeline = sourcePipelines.first }
        }
        .onChange(of: sourcePipelines.count) { _, _ in
            if selectedPipeline == nil { selectedPipeline = sourcePipelines.first }
        }
    }

    // MARK: - Pipeline bar

    private var pipelineBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.sparkles")
                .foregroundStyle(.secondary)
                .font(.caption)

            Picker("", selection: $selectedPipeline) {
                Text("Select Pipeline").tag(Optional<FormattingPipeline>.none)
                ForEach(sourcePipelines) { p in
                    Text(p.name).tag(Optional(p))
                }
            }
            .labelsHidden()
            .fixedSize()

            if viewModel.isRunningPipeline {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if !viewModel.pipelineStep.isEmpty {
                        Text(viewModel.pipelineStep)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button("Cancel") { viewModel.cancelPipeline() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else {
                Button("Run") {
                    guard let p = selectedPipeline else { return }
                    Task { await viewModel.runPipeline(p) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selectedPipeline == nil || viewModel.session.rawText.isEmpty)
            }

            Spacer()

            Text("Runs on this session's transcript")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Pipeline result bubble

private struct PipelineResultBubble: View {
    let text: String
    let onReplace: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Label("Pipeline Result", systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Replace Transcript", action: onReplace)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss result")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 14)

            // Result text (scrollable, max height to avoid dominating chat)
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Thinking indicator

private struct ThinkingIndicator: View {
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Input bar

private struct ChatInputBar: View {
    let isResponding: Bool
    let onSend: (String) -> Void
    let onCancel: () -> Void
    var pipelinePrompts: [(name: String, prompt: String)] = []

    @State private var inputText = ""

    var body: some View {
        HStack(spacing: 8) {
            if !pipelinePrompts.isEmpty {
                Menu {
                    ForEach(pipelinePrompts, id: \.name) { item in
                        Button(item.name) { inputText = item.prompt }
                    }
                } label: {
                    Image(systemName: "text.badge.plus")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isResponding)
                .help("Fill prompt from pipeline")
            }

            TextField("Ask about this session…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .disabled(isResponding)
                .onSubmit {
                    guard !isResponding else { return }
                    send()
                }
                .padding(.vertical, 8)

            if isResponding {
                Button { onCancel() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            } else {
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty && !isResponding
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        onSend(text)
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    var message: ConversationMessage?
    var streamingText: String?
    var onReplaceTranscript: ((String) -> Void)?
    var onAddToTranscript: ((String) -> Void)?

    private var isUser: Bool { message?.role == .user }
    private var text: String { streamingText ?? message?.content ?? "" }
    private var isAssistant: Bool { !isUser && streamingText == nil }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 40) }

            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isUser
                    ? Color.accentColor.opacity(0.15)
                    : Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contextMenu {
                    if isAssistant {
                        if let replace = onReplaceTranscript {
                            Button("Replace Transcript with This") { replace(text) }
                        }
                        if let add = onAddToTranscript {
                            Button("Add to Transcript") { add(text) }
                        }
                        if onReplaceTranscript != nil || onAddToTranscript != nil {
                            Divider()
                        }
                    }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }

            if !isUser { Spacer(minLength: 40) }
        }
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let session = previewSession(in: c)
    return SessionChatView(session: session, context: c.mainContext)
        .modelContainer(c)
        .frame(width: 460, height: 560)
}
