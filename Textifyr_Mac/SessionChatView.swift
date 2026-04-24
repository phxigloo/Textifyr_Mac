import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

struct SessionChatView: View {
    @StateObject private var viewModel: SessionChatViewModel

    init(session: SourceSession, context: ModelContext) {
        _viewModel = StateObject(wrappedValue: SessionChatViewModel(session: session, context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                        }
                        if viewModel.isResponding && !viewModel.streamingResponse.isEmpty {
                            ChatBubble(streamingText: viewModel.streamingResponse)
                                .id("streaming")
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
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            Divider()

            ChatInputBar(isResponding: viewModel.isResponding) { text in
                Task { await viewModel.send(text) }
            }
        }
    }
}

// MARK: - Input bar

private struct ChatInputBar: View {
    let isResponding: Bool
    let onSend: (String) -> Void

    @State private var inputText = ""

    var body: some View {
        HStack(spacing: 10) {
            TextField("Ask about this session…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit {
                    guard !isResponding else { return }
                    send()
                }
                .padding(.vertical, 8)

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

    private var isUser: Bool { message?.role == .user }

    private var text: String { streamingText ?? message?.content ?? "" }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 40) }

            Text(text)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isUser
                    ? Color.accentColor.opacity(0.15)
                    : Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if !isUser { Spacer(minLength: 40) }
        }
    }
}
