import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

struct DocumentHeaderView: View {
    @ObservedObject var viewModel: DocumentEditorViewModel

    @Query(sort: \WorkStage.sortOrder) private var stages: [WorkStage]
    @FocusState private var titleFocused: Bool
    @State private var showStagePicker = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("Document title", text: $viewModel.title)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .onSubmit { viewModel.saveTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { viewModel.saveTitle() }
                }

            Spacer()

            stagePickerButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .onAppear { assignDefaultStage() }
        .onChange(of: stages) { _, _ in assignDefaultStage() }
    }

    // MARK: - Stage picker button

    private var stagePickerButton: some View {
        Button { showStagePicker = true } label: {
            if let stage = viewModel.document.stage {
                StageBadgeView(stage: stage)
            } else {
                Label("Set Stage", systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help(viewModel.document.stage == nil ? "Assign a work stage" : "Change work stage")
        .popover(isPresented: $showStagePicker, arrowEdge: .bottom) {
            stagePopover
        }
    }

    // MARK: - Popover content

    @ViewBuilder
    private var stagePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            stageRows
            if viewModel.document.stage != nil {
                Divider()
                Button {
                    viewModel.clearStage()
                    showStagePicker = false
                } label: {
                    Text("Clear Stage")
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 160)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stageRows: some View {
        ForEach(stages) { (s: WorkStage) in
            Button {
                viewModel.selectStage(s)
                showStagePicker = false
            } label: {
                HStack {
                    Text(s.name)
                    Spacer()
                    if viewModel.document.stage?.id == s.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
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
