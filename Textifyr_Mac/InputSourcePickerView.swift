import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

/// Shown inline in SourcesTabView (no sheet). Creates a single InputCaptureViewModel
/// shared across all input views and injects `wizardDismiss` into the hierarchy.
struct InputSourcePickerView: View {
    let document: TextifyrDocument
    /// When non-nil, the picker opens straight into this method's wizard (used by
    /// menu commands and the Share Extension handoff).
    let initialMethod: CaptureMethod?
    let onDismiss: () -> Void
    @EnvironmentObject private var appState: AppState

    @StateObject private var captureVM: InputCaptureViewModel
    @State private var activeMethod: CaptureMethod?

    private let methods: [CaptureMethod] = [
        .appleIntelligence, .screenCapture, .microphone,
        .audioFile, .videoAudio, .camera,
        .photoLibrary, .imageFile, .rtfEditor,
        .pdf, .webURL, .smartVision
    ]

    init(document: TextifyrDocument,
         context: ModelContext,
         initialMethod: CaptureMethod? = nil,
         onDismiss: @escaping () -> Void) {
        self.document      = document
        self.initialMethod = initialMethod
        self.onDismiss     = onDismiss
        _captureVM = StateObject(wrappedValue: InputCaptureViewModel(
            document: document,
            context: context
        ))
    }

    var body: some View {
        Group {
            if let method = activeMethod {
                inputView(for: method)
            } else {
                pickerGrid
            }
        }
        .environment(\.wizardDismiss, onDismiss)
        .task { captureVM.appState = appState }
        .onAppear {
            // Deterministic auto-select: read the method passed in at construction
            // instead of waiting on a notification that may arrive before mount.
            if activeMethod == nil { activeMethod = initialMethod }
        }
    }

    // MARK: - Picker grid

    private var pickerGrid: some View {
        VStack(spacing: 0) {
            ToolColumnHeader("Add Source")

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 16) {
                    ForEach(methods, id: \.self) { method in
                        SourceMethodButton(method: method, disabled: method == .camera && !appState.canUseCamera) {
                            activeMethod = method
                        }
                    }
                }
                .padding(24)
            }

            ToolColumnFooter {
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Input view routing

    @ViewBuilder
    private func inputView(for method: CaptureMethod) -> some View {
        switch method {
        case .microphone:
            MicrophoneWizardView(captureVM: captureVM)
        case .audioFile, .videoAudio:
            AudioFileWizardView(captureVM: captureVM, captureMethod: method)
        case .imageFile:
            ImageFileImportView(captureVM: captureVM)
        case .photoLibrary:
            PhotoLibraryInputView(captureVM: captureVM)
        case .camera:
            CameraInputView(captureVM: captureVM)
        case .pdf:
            PDFInputView(captureVM: captureVM)
        case .webURL:
            WebInputView(captureVM: captureVM)
        case .screenCapture:
            ScreenCaptureInputView(captureVM: captureVM)
        case .rtfEditor:
            RTFEditorInputView(captureVM: captureVM)
        case .appleIntelligence:
            AppleIntelligenceInputView(captureVM: captureVM)
        case .smartVision:
            SmartVisionInputView(captureVM: captureVM)
        default:
            VStack {
                Text("Coming soon")
                    .foregroundStyle(.secondary)
                Button("Cancel") { onDismiss() }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Method button

private struct SourceMethodButton: View {
    let method: CaptureMethod
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: method.systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
                Text(method.displayName)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(disabled ? Color.secondary : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? "Camera is already in use in another window" : "")
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let doc = previewDocument(in: c)
    return InputSourcePickerView(document: doc, context: c.mainContext, onDismiss: {})
        .modelContainer(c)
        .environmentObject(AppState())
        .frame(width: 560, height: 460)
}
