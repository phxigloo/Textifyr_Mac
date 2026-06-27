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
    @State private var showExportSheet = false

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
            // The right-side "AI Actions" inspector was retired (24.5) — it duplicated the
            // Actions (Library) mode + the per-source drill bar. Edit actions there instead.
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showExportSheet) {
            ExportFormatSheet(viewModel: viewModel)
        }
        // File menu
        .onReceive(NotificationCenter.default.publisher(for: .exportDocument)) { _ in
            showExportSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .printDocument)) { _ in
            showExportSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openInPages)) { _ in
            showExportSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openInNumbers)) { _ in
            showExportSheet = true
        }
        // Tools menu
        .onReceive(NotificationCenter.default.publisher(for: .formatDocument)) { _ in
            selectedTab = .output
            Task { await viewModel.runFormatting(appState: appState) }
        }
        // Audio/video dropped on the Output needs the Sources transcription wizard.
        .onReceive(NotificationCenter.default.publisher(for: .requestSourcesTab)) { _ in
            selectedTab = .sources
        }
        // View-menu "Show AI Actions Inspector" → now opens the Actions (Library) mode (24.5).
        .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in
            appState.editOrigin = nil
            appState.workspaceMode = .actions
        }
        // Push output tab / has-output state so menu items can disable themselves
        .onChange(of: selectedTab) { _, tab in
            appState.outputTabIsActive = (tab == .output)
        }
        .onChange(of: viewModel.document.hasOutput) { _, has in
            appState.activeDocumentHasOutput = has
        }
        .onAppear {
            appState.outputTabIsActive = (selectedTab == .output)
            appState.activeDocumentHasOutput = viewModel.document.hasOutput
        }
        .onDisappear {
            appState.outputTabIsActive = false
            appState.activeDocumentHasOutput = false
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
            RTFOutputView(viewModel: viewModel, showExportSheet: $showExportSheet)
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
