import SwiftUI
import SwiftData
import AppKit
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct RTFOutputView: View {
    @ObservedObject var viewModel: DocumentEditorViewModel
    @EnvironmentObject private var appState: AppState
    @StateObject private var formatState = TextFormatState()

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "output" },
           sort: \FormattingPipeline.name) private var outputPipelines: [FormattingPipeline]

    @State private var showExportSheet = false
    @State private var showPipelineEditor = false

    private var document: TextifyrDocument { viewModel.document }

    private var pictureSessions: [SourceSession] {
        (document.sourceSessions ?? [])
            .filter { $0.isPictureSession }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ZStack {
                contentArea
                if viewModel.isFormatting {
                    formattingOverlay
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportFormatSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showPipelineEditor) {
            ScopedPipelineEditorSheet(scope: .output)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Output")
                .font(.headline)

            Spacer()


            // Pipeline picker
            Menu {
                ForEach(outputPipelines) { pipeline in
                    Button {
                        viewModel.selectPipeline(pipeline)
                    } label: {
                        HStack {
                            Text(pipeline.name)
                            if document.pipeline?.id == pipeline.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if !outputPipelines.isEmpty { Divider() }
                Button {
                    showPipelineEditor = true
                } label: {
                    Label("Manage Pipelines…", systemImage: "slider.horizontal.3")
                }
            } label: {
                Label(
                    document.pipeline?.name ?? "Pipeline",
                    systemImage: "wand.and.sparkles"
                )
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Select a formatting pipeline")

            // Format / Cancel
            if viewModel.isFormatting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if !viewModel.formattingStep.isEmpty {
                        Text(viewModel.formattingStep)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 200)
                    }
                    Button("Cancel") {
                        viewModel.cancelFormatting(appState: appState)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button {
                    Task { await viewModel.runFormatting(appState: appState) }
                } label: {
                    Label("Format", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(document.pipeline == nil ||
                          document.mergedSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Run AI formatting pipeline")
            }

            if document.hasOutput && !viewModel.isFormatting {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Export document")

                Button {
                    viewModel.clearOutput()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Clear formatted output")
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .background(.bar)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if document.hasOutput {
            VStack(spacing: 0) {
                FormattingToolbar(fmt: formatState)
                Divider()
                RichTextEditor(
                    rtfData: Binding(
                        get: { document.outputRTF },
                        set: { document.outputRTF = $0 }
                    ),
                    isEditable: true,
                    formatState: formatState
                )
                if !pictureSessions.isEmpty {
                    Divider()
                    pictureStrip
                }
            }
        } else if !viewModel.isFormatting {
            emptyState
        }
    }

    // MARK: - Picture strip

    private var pictureStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Picture Sources")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text("(\(pictureSessions.count))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Included in RTF export")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(pictureSessions, id: \.id) { session in
                        PictureThumbnailView(session: session)
                    }
                }
                .padding(10)
            }
            .frame(height: 120)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: - Formatting overlay

    private var formattingOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
                if !viewModel.formattingStep.isEmpty {
                    Text(viewModel.formattingStep)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
        }
        .ignoresSafeArea()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No formatted output yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Select a pipeline and tap Format.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Picture thumbnail

private struct PictureThumbnailView: View {
    let session: SourceSession

    var body: some View {
        VStack(spacing: 4) {
            if let pngData = session.rawRTFData, let nsImage = NSImage(data: pngData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
            }
            if !session.rawText.isEmpty {
                Text(session.previewText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: 80)
            }
        }
    }
}

#Preview("Empty output") { @MainActor in
    let c = makePreviewContainer()
    let appState = previewAppState(selectedIn: c)
    let vm = previewDocumentVM(in: c)
    return RTFOutputView(viewModel: vm)
        .modelContainer(c)
        .environmentObject(appState)
        .frame(width: 580, height: 500)
}
