import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

struct SessionDetailView: View {
    let session: SourceSession
    let document: TextifyrDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(session.captureMethod.displayName, systemImage: session.captureMethod.systemImage)
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            TabView(selection: $selectedTab) {
                ScrollView {
                    Text(session.rawText.isEmpty ? "No transcription text." : session.rawText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .tabItem { Label("Transcript", systemImage: "text.alignleft") }
                .tag(0)

                SessionChatView(session: session, context: modelContext)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(1)
            }
            .frame(minWidth: 540, minHeight: 440)
        }
    }
}
