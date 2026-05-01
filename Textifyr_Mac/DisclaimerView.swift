import SwiftUI
import TextifyrModels
import TextifyrServices

struct DisclaimerView: View {
    @AppStorage(AppConstants.hasAcceptedTermsKey) private var hasAcceptedTerms = false
    @State private var hasScrolledToBottom = false
    @State private var acknowledgedAI = false

    var canProceed: Bool { hasScrolledToBottom && acknowledgedAI }

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
                        content: "Textifyr captures text from your microphone, audio files, video, camera, photos, PDFs, and web pages, then uses Apple Intelligence to format and summarise it. All AI processing happens on-device or via Apple Private Cloud Compute — never on third-party servers."
                    )

                    TermsSection(
                        title: "Apple Intelligence & Privacy",
                        icon: "wand.and.sparkles",
                        content: "When you use AI formatting or chat features, your text is processed using Apple's Foundation Models framework. Requests may be handled entirely on your device or routed to Apple Private Cloud Compute (PCC) when the task exceeds on-device capacity. Apple does not retain your data from PCC requests, cannot access it, and does not use it to train models. No data is ever sent to Textifyr or any third party."
                    )

                    TermsSection(
                        title: "AI Accuracy & Limitations",
                        icon: "exclamationmark.triangle",
                        accentColor: .orange,
                        content: "Apple Intelligence results may be inaccurate, incomplete, or misleading. Always review AI-formatted output before using it. Do not rely on Textifyr output for medical, legal, financial, safety-critical, or other high-stakes decisions. The Foundation Models framework is licensed for personal productivity use and must not be used to generate harmful, deceptive, or unlawful content."
                    )

                    TermsSection(
                        title: "Your Responsibility for Content",
                        icon: "person.fill.checkmark",
                        accentColor: .orange,
                        content: "You are solely responsible for ensuring you have the legal right to capture, transcribe, and process any content you import. This includes audio recordings, photographs, documents, and web pages that may be subject to copyright, confidentiality, or privacy obligations."
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
                        content: "Textifyr only accesses the microphone and camera when you explicitly start a capture session. Recordings are processed locally and are not retained after transcription unless you save them to a document."
                    )

                    TermsSection(
                        title: "iCloud Sync & Your Data",
                        icon: "icloud",
                        content: "Your documents, transcripts, and formatting pipelines sync privately via iCloud CloudKit using end-to-end encryption. Only you can access your data. You can disable sync at any time in System Settings → Apple ID → iCloud. To delete all your data, delete your documents within Textifyr and disable iCloud sync — no data is retained on any server."
                    )

                    TermsSection(
                        title: "No Telemetry or Third-Party Tracking",
                        icon: "eye.slash",
                        content: "Textifyr collects no analytics, crash reports, or telemetry. Your documents never leave your devices except through your own iCloud account. No advertising identifiers or third-party SDKs are included."
                    )

                    TermsSection(
                        title: "Privacy Policy",
                        icon: "lock.shield",
                        content: "A full Privacy Policy describing all data practices is available in Textifyr Settings → About → Privacy Policy. The policy covers data collection, use, retention, and your rights. By using Textifyr you acknowledge that you have read and understood this policy. If the policy changes, you will be notified within the app."
                    )

                    // Scroll sentinel — detects when user has reached the bottom
                    Color.clear
                        .frame(height: 1)
                        .onAppear { hasScrolledToBottom = true }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
            .frame(maxHeight: 340)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 32)

            // Acknowledgement checkbox + accept
            VStack(spacing: 12) {
                Toggle(isOn: $acknowledgedAI) {
                    Text("I understand that AI-generated content may be inaccurate and should not be used for medical, legal, or financial decisions.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 4)

                Button {
                    hasAcceptedTerms = true
                } label: {
                    Text("Accept & Get Started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canProceed)

                Text("By accepting, you confirm you have read these disclosures, will only process content you have the legal right to use, and agree to the Privacy Policy available in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .frame(width: 600, height: 780)
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
