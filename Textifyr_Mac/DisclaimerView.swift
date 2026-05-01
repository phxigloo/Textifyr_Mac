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
            .padding(.top, 40)
            .padding(.bottom, 24)

            // Terms scroll area
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    TermsSection(
                        title: "What Textifyr Does",
                        icon: "text.viewfinder",
                        content: "Textifyr captures text from your microphone, audio files, video, camera, photos, PDFs, and web pages, then uses Apple Intelligence to format and summarise it. All processing happens on-device or via Apple Private Cloud Compute — never on third-party servers."
                    )

                    TermsSection(
                        title: "Apple Intelligence & Privacy",
                        icon: "wand.and.sparkles",
                        content: "When you use AI formatting features, your text may be processed on-device or securely on Apple Private Cloud Compute. Apple does not retain your data or use it to train models. No data is sent to Textifyr or any third party."
                    )

                    TermsSection(
                        title: "Your Responsibility for Content",
                        icon: "person.fill.checkmark",
                        accentColor: .orange,
                        content: "Textifyr is a personal productivity tool. You are solely responsible for ensuring you have the legal right to capture, transcribe, and process any content you import. This includes audio recordings, photographs, documents, and web pages that may be subject to copyright, confidentiality, or privacy obligations."
                    )

                    TermsSection(
                        title: "Copyright & Responsible Use",
                        icon: "c.circle",
                        accentColor: .orange,
                        content: "Do not use Textifyr to reproduce, redistribute, or publish copyrighted material without the rights holder's permission. Processing a copyrighted work for your own private reference is generally permitted under fair use or fair dealing; mass reproduction or redistribution is not. Textifyr will alert you when captured text appears to contain copyright notices."
                    )

                    TermsSection(
                        title: "Recording & Consent",
                        icon: "mic.fill",
                        content: "Only record conversations with the knowledge and consent of all participants as required by the laws in your jurisdiction. Many regions require all-party consent for audio recording."
                    )

                    TermsSection(
                        title: "Microphone & Camera Access",
                        icon: "camera.fill",
                        content: "Textifyr only accesses the microphone and camera when you explicitly start a capture session. Recordings are processed locally and not retained after transcription unless you save them to a document."
                    )

                    TermsSection(
                        title: "iCloud Sync",
                        icon: "icloud",
                        content: "Your documents sync privately via iCloud CloudKit. Only you can access your data. You can disable sync at any time in System Settings → Apple ID → iCloud."
                    )

                    TermsSection(
                        title: "No Telemetry",
                        icon: "eye.slash",
                        content: "No analytics, crash reports, or telemetry are collected. Your documents never leave your devices except through your own iCloud account."
                    )

                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
            .frame(maxHeight: 340)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 32)

            // Accept area
            VStack(spacing: 10) {
                Button {
                    hasAcceptedTerms = true
                } label: {
                    Text("I Accept These Terms — Get Started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("By accepting, you confirm that you will only process content you have the legal right to use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .frame(width: 580, height: 720)
    }
}

// MARK: - Section component

private struct TermsSection: View {
    let title: String
    let icon: String
    var accentColor: Color = .accentColor
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(accentColor)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(content)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    DisclaimerView()
        .frame(width: 640, height: 560)
}
