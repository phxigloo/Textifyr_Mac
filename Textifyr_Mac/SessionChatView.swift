import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

struct SessionChatView: View {
    @StateObject private var viewModel: SessionChatViewModel
    var onReplaceTranscript: ((String) -> Void)?
    var onAddToTranscript: ((String) -> Void)?

    init(session: SourceSession, context: ModelContext,
         onReplaceTranscript: ((String) -> Void)? = nil,
         onAddToTranscript: ((String) -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: SessionChatViewModel(session: session, context: context))
        self.onReplaceTranscript = onReplaceTranscript
        self.onAddToTranscript   = onAddToTranscript
    }

    var body: some View {
        VStack(spacing: 0) {
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
                        if viewModel.isResponding {
                            if viewModel.streamingResponse.isEmpty {
                                ThinkingIndicator()
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
                .onChange(of: viewModel.isResponding) { _, responding in
                    if responding { proxy.scrollTo("thinking", anchor: .bottom) }
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

            ChatInputBar(isResponding: viewModel.isResponding,
                         onSend: { text in Task { await viewModel.send(text) } },
                         onCancel: { viewModel.cancelResponse() })
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
    }
}

// MARK: - Input bar

private struct ChatInputBar: View {
    let isResponding: Bool
    let onSend: (String) -> Void
    let onCancel: () -> Void

    @State private var inputText = ""

    var body: some View {
        HStack(spacing: 10) {
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
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
                .help("Cancel response")
            } else {
                Button {
                    send()
                } label: {
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

// MARK: - Thinking indicator

private struct ThinkingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Apple Intelligence is thinking…")
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
