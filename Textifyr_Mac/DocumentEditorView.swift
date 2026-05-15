import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

private enum DocumentTab: CaseIterable {
    case sources, output
    var title: String { self == .sources ? "Sources" : "Output" }
    var icon: String  { self == .sources ? "waveform.and.mic" : "wand.and.sparkles" }
}

struct DocumentEditorView: View {
    @StateObject private var viewModel: DocumentEditorViewModel
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: DocumentTab = .sources

    init(document: TextifyrDocument, context: ModelContext) {
        _viewModel = StateObject(wrappedValue: DocumentEditorViewModel(document: document, context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            DocumentHeaderView(viewModel: viewModel)
            Divider()
            errorBanner
            tabBar
            Divider()
            HSplitView {
                tabContent
                    .frame(minWidth: 400, maxWidth: .infinity)
                if appState.inspectorVisible {
                    PipelineInspectorView()
                        .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Error banner

    @ViewBuilder
    private var errorBanner: some View {
        if let msg = viewModel.errorMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(msg).font(.caption)
                Spacer()
                Button("Dismiss") { viewModel.errorMessage = nil }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.yellow.opacity(0.1))
            Divider()
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(DocumentTab.allCases, id: \.title) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.subheadline)
                        .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            selectedTab == tab
                                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.18)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if !appState.inspectorVisible {
                        appState.inspectorDefaultScope = selectedTab == .output ? .output : .source
                    }
                    appState.inspectorVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(appState.inspectorVisible ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(appState.inspectorVisible ? "Hide AI Actions Inspector" : "Show AI Actions Inspector")
            .padding(.trailing, 14)
        }
        .frame(height: 34)
        .padding(.leading, 8)
        .background(.bar)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .sources:
            SourcesTabView(document: viewModel.document, viewModel: viewModel)
        case .output:
            RTFOutputView(viewModel: viewModel)
        }
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let doc = previewDocument(in: c)
    let appState = previewAppState(selectedIn: c)
    return DocumentEditorView(document: doc, context: c.mainContext)
        .modelContainer(c)
        .environmentObject(appState)
        .frame(width: 960, height: 640)
}
