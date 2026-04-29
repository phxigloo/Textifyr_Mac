import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

struct DocumentEditorView: View {
    @StateObject private var viewModel: DocumentEditorViewModel
    @EnvironmentObject private var appState: AppState

    init(document: TextifyrDocument, context: ModelContext) {
        _viewModel = StateObject(wrappedValue: DocumentEditorViewModel(document: document, context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            DocumentHeaderView(viewModel: viewModel)
            Divider()

            if let errorMessage = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(errorMessage)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { viewModel.errorMessage = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.1))
                Divider()
            }

            HSplitView {
                // Left: source sessions
                SourceSessionListView(document: viewModel.document, viewModel: viewModel)
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)

                // Right: formatted output
                RTFOutputView(viewModel: viewModel)
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
