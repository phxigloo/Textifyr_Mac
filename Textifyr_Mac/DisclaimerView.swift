import SwiftUI
import TextifyrModels
import TextifyrServices

struct DisclaimerView: View {
    @AppStorage(AppConstants.hasAcceptedTermsKey) private var hasAcceptedTerms = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                Text("Welcome to Textifyr")
                    .font(.largeTitle).bold()
                Text("Capture, transcribe, and format text with Apple Intelligence")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 48)
            .padding(.bottom, 32)

            // Terms scroll area
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TermsSection(title: "What Textifyr Does",
                                 content: "Textifyr captures text from your microphone, audio files, video, camera, photos, PDFs, and web pages, then uses Apple Intelligence to format and summarise it. All processing happens on-device or via Apple Private Cloud Compute.")

                    TermsSection(title: "Apple Intelligence & Privacy",
                                 content: "When you use AI formatting features, your text may be processed on-device or securely on Apple Private Cloud Compute. Apple does not retain your data or use it to train models. No data is sent to third-party servers.")

                    TermsSection(title: "Microphone & Camera",
                                 content: "Textifyr only accesses the microphone and camera when you explicitly start a capture session. Recordings are stored temporarily and deleted after transcription unless you save them.")

                    TermsSection(title: "iCloud Sync",
                                 content: "Your documents sync privately via iCloud CloudKit. Only you can access your data. You can disable sync in System Settings → Apple ID → iCloud.")

                    TermsSection(title: "Data Storage",
                                 content: "Documents are stored locally in your app container and optionally in your private iCloud. No analytics or telemetry are collected.")
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            }
            .frame(maxHeight: 320)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 40)

            // Accept button
            Button {
                hasAcceptedTerms = true
            } label: {
                Text("I Agree — Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .frame(width: 560, height: 680)
    }
}

private struct TermsSection: View {
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(content).font(.body).foregroundStyle(.secondary)
        }
    }
}
