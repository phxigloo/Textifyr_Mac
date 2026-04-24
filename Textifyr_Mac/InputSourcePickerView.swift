import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

/// Sheet presented when the user taps "+" in SourceSessionListView.
/// Creates a single InputCaptureViewModel shared across all input views.
struct InputSourcePickerView: View {
    let document: TextifyrDocument
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @StateObject private var captureVM: InputCaptureViewModel
    @State private var activeMethod: CaptureMethod?

    private let methods: [CaptureMethod] = [
        .microphone, .audioFile, .videoAudio,
        .camera, .imageFile,
        .pdf, .webURL,
        .screenCapture, .rtfEditor
    ]

    init(document: TextifyrDocument, context: ModelContext) {
        self.document = document
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
        .task { captureVM.appState = appState }
    }

    // MARK: - Picker grid

    private var pickerGrid: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Source")
                    .font(.title2).bold()
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 16) {
                ForEach(methods, id: \.self) { method in
                    SourceMethodButton(method: method) {
                        activeMethod = method
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 480)
    }

    // MARK: - Input view routing

    @ViewBuilder
    private func inputView(for method: CaptureMethod) -> some View {
        switch method {
        case .microphone:
            LiveTranscriptionView(captureVM: captureVM)
        case .audioFile, .videoAudio:
            AudioFileImportView(captureVM: captureVM, captureMethod: method)
        case .imageFile:
            ImageFileImportView(captureVM: captureVM)
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
        default:
            Text("Coming soon")
                .frame(width: 480, height: 320)
        }
    }
}

// MARK: - Method button

private struct SourceMethodButton: View {
    let method: CaptureMethod
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: method.systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                Text(method.displayName)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
