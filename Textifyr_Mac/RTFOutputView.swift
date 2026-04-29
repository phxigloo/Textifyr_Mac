import SwiftUI
import AppKit
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct RTFOutputView: View {
    @ObservedObject var viewModel: DocumentEditorViewModel
    @StateObject private var formatState = TextFormatState()
    @State private var showExportSheet = false

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
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Output")
                .font(.headline)
            Spacer()
            if document.hasOutput && !viewModel.isFormatting {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Export document")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                VStack(spacing: 4) {
                    Text("Formatting…")
                        .font(.headline)
                    if !viewModel.formattingStep.isEmpty {
                        Text(viewModel.formattingStep)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
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
            Text("Add sources and run the formatting pipeline.")
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
