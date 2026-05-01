import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

struct DocumentHeaderView: View {
    @ObservedObject var viewModel: DocumentEditorViewModel

    @Query(sort: \WorkStage.sortOrder) private var stages: [WorkStage]
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField("Document title", text: $viewModel.title)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .onSubmit { viewModel.saveTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { viewModel.saveTitle() }
                }

            Spacer()

            // Display-only stage badge — change stage from the sidebar
            if let stage = viewModel.document.stage {
                StageBadgeView(stage: stage)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .onAppear { assignDefaultStage() }
        .onChange(of: stages) { _, _ in assignDefaultStage() }
    }

    private func assignDefaultStage() {
        guard viewModel.document.stage == nil, let first = stages.first else { return }
        viewModel.selectStage(first)
    }
}


#Preview { @MainActor in
    let c = makePreviewContainer()
    let vm = previewDocumentVM(in: c)
    return DocumentHeaderView(viewModel: vm)
        .modelContainer(c)
        .frame(width: 700)
}
