import SwiftUI
import AppKit
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct ScreenCaptureInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var capturedDisplays: [(name: String, image: CGImage)] = []
    @State private var selectedImage: CGImage?
    @State private var carouselIndex = 0
    @State private var recognizedText = ""
    @State private var isCapturing = false
    @State private var isProcessing = false
    @State private var showingCropView = false
    @State private var showPrepareSheet = false
    @State private var suppressPrepare = false
    @State private var hasTriggeredCapture = false
    @State private var errorText: String?
    @State private var permissionDenied = false

    private static let suppressKey = "suppressScreenCapturePrepareAlert"

    var body: some View {
        VStack(spacing: 20) {
            Text("Screen Capture")
                .font(.title2).bold()
                .padding(.top, 24)

            if isCapturing {
                capturingContent
            } else if !capturedDisplays.isEmpty && selectedImage == nil {
                carouselContent
            } else if selectedImage != nil {
                reviewContent
            } else {
                promptContent
            }
        }
        .frame(minWidth: 560)
        .sheet(isPresented: $showPrepareSheet) {
            prepareSheet
        }
        .sheet(isPresented: $showingCropView) {
            if let image = selectedImage {
                NavigationStack {
                    CroppableImageView(
                        image: image,
                        onCrop: { cropped in
                            showingCropView = false
                            Task { await processCroppedImage(cropped) }
                        },
                        onCancel: { showingCropView = false }
                    )
                    .navigationTitle("Crop Region")
                }
                .frame(minWidth: 640, minHeight: 500)
            }
        }
        .alert("Capture Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
        .onAppear {
            if !hasTriggeredCapture {
                hasTriggeredCapture = true
                if UserDefaults.standard.bool(forKey: Self.suppressKey) {
                    Task { try? await Task.sleep(for: .milliseconds(400)); await captureScreens() }
                } else {
                    showPrepareSheet = true
                }
            }
        }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }

    // MARK: - Content states

    @ViewBuilder private var promptContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Capture a screenshot to extract text. Textifyr is automatically excluded.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)

            if permissionDenied {
                permissionDeniedView
            } else {
                if let error = errorText { Text(error).font(.caption).foregroundStyle(.red) }

                Button("Capture Screen") {
                    if UserDefaults.standard.bool(forKey: Self.suppressKey) {
                        Task { await captureScreens() }
                    } else {
                        showPrepareSheet = true
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Cancel") { captureVM.reset(); dismiss() }
                .buttonStyle(.bordered).padding(.bottom, 28)
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder private var capturingContent: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Capturing…").font(.headline)
        }
        .frame(height: 200)
    }

    // MARK: - Multi-display carousel

    @ViewBuilder private var carouselContent: some View {
        VStack(spacing: 12) {
            Text("Select Display")
                .font(.headline)

            Text("\(capturedDisplays[carouselIndex].name)")
                .font(.subheadline).foregroundStyle(.secondary)

            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { carouselIndex = max(carouselIndex - 1, 0) }
                } label: {
                    Image(systemName: "chevron.left").font(.title2.bold())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(carouselIndex == 0)
                .opacity(carouselIndex == 0 ? 0.3 : 1)

                let img = capturedDisplays[carouselIndex].image
                Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                    .resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    .padding(.horizontal, 8)
                    .id(carouselIndex)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { carouselIndex = min(carouselIndex + 1, capturedDisplays.count - 1) }
                } label: {
                    Image(systemName: "chevron.right").font(.title2.bold())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(carouselIndex >= capturedDisplays.count - 1)
                .opacity(carouselIndex >= capturedDisplays.count - 1 ? 0.3 : 1)
            }

            HStack(spacing: 8) {
                ForEach(capturedDisplays.indices, id: \.self) { i in
                    Circle()
                        .fill(i == carouselIndex ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                        .onTapGesture { withAnimation { carouselIndex = i } }
                }
            }

            HStack(spacing: 16) {
                Button("Recapture") {
                    capturedDisplays = []; carouselIndex = 0
                    Task { await captureScreens() }
                }
                .buttonStyle(.bordered)

                Button {
                    selectedImage = capturedDisplays[carouselIndex].image
                    showingCropView = true
                } label: {
                    Label("Use This Display", systemImage: "crop")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal)
    }

    // MARK: - Review (crop + text)

    @ViewBuilder private var reviewContent: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Recognised Text", systemImage: "text.viewfinder")
                    .font(.headline).foregroundStyle(.secondary)
                Spacer()
                if isProcessing { ProgressView().controlSize(.small) }

                Button("Crop") { showingCropView = true }.buttonStyle(.bordered)

                Button("Clear") { recognizedText = "" }
                    .buttonStyle(.bordered).disabled(recognizedText.isEmpty)

                if capturedDisplays.count > 1 {
                    Button("Switch Display") { selectedImage = nil }.buttonStyle(.bordered)
                }

                Button("Recapture") {
                    capturedDisplays = []; selectedImage = nil; recognizedText = ""; carouselIndex = 0
                    Task { await captureScreens() }
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Text("Crop to select regions for OCR. Each crop appends to the text below.")
                .font(.caption).foregroundStyle(.tertiary).padding(.horizontal)

            if recognizedText.isEmpty && !isProcessing {
                Text("No text yet — use Crop to recognise a region.")
                    .font(.body).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                TextEditor(text: $recognizedText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
            }

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            HStack {
                Button("Cancel") { captureVM.reset(); dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Use Text") {
                    captureVM.saveTextCapture(recognizedText, captureMethod: .screenCapture)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
            }
            .padding([.horizontal, .bottom])
        }
    }

    // MARK: - Permission denied

    @ViewBuilder private var permissionDeniedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("Screen Recording Permission Required")
                .font(.headline)

            Text("Textifyr needs Screen Recording access to capture your screen. Grant it in System Settings, then try again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
                    )
                }
                .buttonStyle(.borderedProminent)

                Button("Try Again") {
                    permissionDenied = false
                    errorText = nil
                    Task { await captureScreens() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Prepare sheet

    @ViewBuilder private var prepareSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 40)).foregroundStyle(.tint)

            Text("Prepare Your Screen")
                .font(.title3.bold())

            Text("Arrange the windows you want to capture before proceeding. Textifyr is automatically excluded from the screenshot.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20)

            Toggle("Don't show this again", isOn: $suppressPrepare)
                .toggleStyle(.checkbox).padding(.top, 4)

            HStack(spacing: 12) {
                Button("Cancel") { showPrepareSheet = false }
                    .buttonStyle(.bordered).keyboardShortcut(.cancelAction)

                Button("Capture Now") {
                    if suppressPrepare { UserDefaults.standard.set(true, forKey: Self.suppressKey) }
                    showPrepareSheet = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        await captureScreens()
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24).frame(width: 380)
    }

    // MARK: - Actions

    private func captureScreens() async {
        isCapturing = true
        errorText = nil
        do {
            let results = try await ScreenCaptureService.captureAllDisplays()
            isCapturing = false
            if results.count == 1 {
                selectedImage = results[0].image
                showingCropView = true
            } else {
                capturedDisplays = results
                carouselIndex = 0
            }
        } catch {
            isCapturing = false
            let desc = error.localizedDescription.lowercased()
            if desc.contains("tcc") || desc.contains("declined") || desc.contains("not authorized") || desc.contains("permission") {
                permissionDenied = true
            } else {
                errorText = "Screen capture failed: \(error.localizedDescription)"
            }
        }
    }

    private func processCroppedImage(_ cgImage: CGImage) async {
        guard !isProcessing else { return }
        isProcessing = true
        do {
            let text = try await VisionTextService.recognizeText(in: cgImage)
            if text.isEmpty {
                errorText = "No text detected in the cropped region."
            } else {
                recognizedText = recognizedText.isEmpty ? text : recognizedText + "\n\n--- Crop ---\n\n" + text
            }
        } catch {
            errorText = error.localizedDescription
        }
        isProcessing = false
    }
}
