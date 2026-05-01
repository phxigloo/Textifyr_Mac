import SwiftUI
import SwiftData
import AppKit
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct SessionDetailView: View {
    let session: SourceSession
    let document: TextifyrDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab = 0
    @State private var editedText = ""
    @State private var editedRTF: Data? = nil
    @StateObject private var formatState = TextFormatState()
    @State private var showVolumeWarning = false

    // PNG magic bytes: 89 50 4E 47 ("‰PNG")
    private var isPictureSession: Bool {
        guard let d = session.rawRTFData, d.count >= 4 else { return false }
        return d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47
    }
    // Non-PNG data stored in rawRTFData — e.g. RTF editor sessions
    private var isRTFSession: Bool { session.rawRTFData != nil && !isPictureSession }

    private var hasUnsavedChanges: Bool {
        isRTFSession ? editedRTF != session.rawRTFData : editedText != session.rawText
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(session.captureMethod.displayName, systemImage: session.captureMethod.systemImage)
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!hasUnsavedChanges)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            // Copyright warning — shown when captured text contains copyright markers
            if session.containsCopyrightNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "c.circle.fill")
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Possible copyrighted content")
                            .font(.caption.bold())
                        Text("This session appears to contain copyrighted material. Ensure you have the legal right to use and distribute this content.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
                Divider()
            }

            if isRTFSession {
                FormattingToolbar(fmt: formatState)
                Divider()
            }

            TabView(selection: $selectedTab) {
                contentTab
                    .tabItem {
                        Label(
                            isPictureSession ? "Picture" : "Transcript",
                            systemImage: isPictureSession ? "photo" : "text.alignleft"
                        )
                    }
                    .tag(0)

                SessionChatView(
                    session: session,
                    context: modelContext,
                    onReplaceTranscript: { text in handleReplace(text) },
                    onAddToTranscript:   { text in handleAppend(text) }
                )
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(1)
            }
            .frame(minWidth: 540, minHeight: 440)
        }
        .onAppear {
            editedText = session.rawText
            editedRTF  = session.rawRTFData
            if session.rawText.count > AppConstants.copyrightVolumeWarningChars {
                showVolumeWarning = true
            }
        }
        .alert("Large Volume of Content", isPresented: $showVolumeWarning) {
            Button("I Understand", role: .cancel) { }
        } message: {
            Text("This session contains \(session.rawText.count.formatted()) characters of text. Processing large volumes of copyrighted material beyond personal use may not be permitted. Please ensure you have the legal right to use this content.")
        }
    }

    // MARK: - Content tab

    @ViewBuilder
    private var contentTab: some View {
        if isPictureSession {
            pictureSessionView
        } else if isRTFSession {
            RichTextEditor(rtfData: $editedRTF, isEditable: true, formatState: formatState)
        } else {
            TextEditor(text: $editedText)
                .font(.body)
                .padding(16)
        }
    }

    // Picture displayed natively; notes/AI responses go in the text area below.
    private var pictureSessionView: some View {
        VStack(spacing: 0) {
            if let pngData = session.rawRTFData, let nsImage = NSImage(data: pngData) {
                ScrollView {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .frame(maxHeight: 300)
                .background(Color(nsColor: .textBackgroundColor))
            }

            Divider()

            TextEditor(text: $editedText)
                .font(.body)
                .padding(8)
                .frame(minHeight: 80)
        }
    }

    // MARK: - Chat callbacks

    private func handleReplace(_ text: String) {
        if isRTFSession {
            let attr = NSAttributedString(string: text)
            editedRTF = attr.rtf(
                from: NSRange(location: 0, length: attr.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
        } else {
            editedText = text
        }
        selectedTab = 0
    }

    private func handleAppend(_ text: String) {
        if isRTFSession {
            guard let data = editedRTF,
                  let existing = NSMutableAttributedString(rtf: data, documentAttributes: nil) else {
                handleReplace(text)
                return
            }
            existing.append(NSAttributedString(string: "\n\n" + text))
            editedRTF = existing.rtf(
                from: NSRange(location: 0, length: existing.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
        } else {
            // Both plain text and picture sessions use editedText for notes
            editedText = editedText.isEmpty ? text : editedText + "\n\n" + text
        }
        selectedTab = 0
    }

    // MARK: - Save

    private func save() {
        if isRTFSession {
            session.rawRTFData = editedRTF
        } else {
            // Picture sessions: PNG stays in rawRTFData; only text notes change
            session.rawText = editedText
        }
        session.document?.modificationDate = Date()
        try? modelContext.save()
        dismiss()
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let doc = previewDocument(in: c)
    let session = previewSession(in: c)
    return SessionDetailView(session: session, document: doc)
        .modelContainer(c)
        .frame(width: 700, height: 560)
}
