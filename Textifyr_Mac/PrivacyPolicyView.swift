import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Privacy Policy")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Effective date: 1 May 2026  ·  Version 1.0  ·  macOS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // 1. Overview
                    PPSection(number: 1, title: "Overview") {
                        PPBody("Textifyr is a personal productivity application for macOS that captures, transcribes, and formats text using Apple Intelligence. This policy explains exactly what data Textifyr processes, how it is stored, and your rights regarding that data.")
                        PPCallout("The short version: Textifyr processes your content locally on your device. No data is sent to the developer or any third-party service. AI processing uses Apple's infrastructure exclusively. Sync, if enabled, uses your private iCloud account.")
                    }

                    // 2. Data Processed
                    PPSection(number: 2, title: "Data Textifyr Processes") {
                        PPSubsection(title: "2.1 Audio and Video") {
                            PPBody("When you use microphone recording, audio file import, or video import, Textifyr:")
                            PPBullets([
                                "Records or reads audio locally on your device only",
                                "Transcribes speech using Apple's on-device Speech Recognition framework",
                                "Does not upload audio to any server (including the developer's)",
                                "Retains audio or transcribed text only if you explicitly save it to a document",
                                "Deletes working audio from memory immediately after transcription",
                            ])
                        }
                        PPSubsection(title: "2.2 Camera and Images") {
                            PPBody("When you use Camera Input, Photo Library Input, or Image File Import, Textifyr:")
                            PPBullets([
                                "Accesses the camera or selected images only when you explicitly trigger the feature",
                                "Runs optical character recognition (OCR) entirely on-device using Apple's Vision framework",
                                "Does not store captured images unless you save the resulting text to a document",
                                "Discards raw image data from memory after OCR completes",
                            ])
                        }
                        PPSubsection(title: "2.3 Screen Captures") {
                            PPBody("When you use Screen Capture Input, Textifyr:")
                            PPBullets([
                                "Captures your display only when you tap \"Capture Now\"",
                                "Automatically excludes the Textifyr application window from captures",
                                "Processes the screenshot on-device using Vision OCR",
                                "Discards the screenshot immediately after you extract text or dismiss the session",
                            ])
                        }
                        PPSubsection(title: "2.4 PDF and Document Files") {
                            PPBody("When you import PDF or document files, file content is read and extracted locally. No file content is uploaded anywhere. Content is retained only if you save it to a Textifyr document.")
                        }
                        PPSubsection(title: "2.5 Web Content") {
                            PPBody("When you use Web Input, Textifyr loads the URL you enter using a local WebKit web view. Page content is processed on your device. Textifyr does not log, store, or transmit the URLs you visit or the content retrieved.")
                        }
                        PPSubsection(title: "2.6 Documents and Transcripts") {
                            PPBody("When you save content in Textifyr, the following data is stored in a local SwiftData database on your Mac:")
                            PPTable(rows: [
                                ("Documents", "Title, work stage, creation/modification dates"),
                                ("Source sessions", "Transcribed text, capture method, timestamps"),
                                ("Formatted output", "AI-formatted RTF text"),
                                ("Formatting pipelines", "Pipeline names and your custom AI prompt text"),
                                ("Work stages", "Stage names, colours you configure"),
                                ("Chat messages", "Your questions and AI responses within a session"),
                                ("App preferences", "Settings choices (stored in macOS user defaults)"),
                            ])
                        }
                        PPSubsection(title: "2.7 What Textifyr Does Not Collect") {
                            PPBullets([
                                "No analytics or telemetry — no usage data, event logs, or feature tracking",
                                "No crash reports — no third-party crash reporting SDKs",
                                "No advertising identifiers — IDFA or similar are never accessed",
                                "No contact data — no access to your address book",
                                "No location data — no location services are used",
                                "No health data — no HealthKit access",
                                "No third-party SDKs — Textifyr contains no third-party analytics, advertising, or tracking libraries",
                            ])
                        }
                    }

                    // 3. Apple Intelligence
                    PPSection(number: 3, title: "Apple Intelligence and AI Processing") {
                        PPBody("Textifyr uses Apple's Foundation Models framework (Apple Intelligence) to format text, generate summaries, and power the session chat feature.")
                        PPSubsection(title: "3.1 How AI Requests Are Processed") {
                            PPBody("When you run a formatting pipeline or send a chat message, your text is processed by Apple's Foundation Models framework. Apple routes each request to whichever inference path is most appropriate:")
                            PPBullets([
                                "On-device inference — your text never leaves your Mac",
                                "Apple Private Cloud Compute (PCC) — used for complex requests that exceed on-device capacity",
                            ])
                        }
                        PPSubsection(title: "3.2 Apple Private Cloud Compute Guarantees") {
                            PPBody("Apple has published independently verified guarantees for PCC:")
                            PPBullets([
                                "Apple cannot access your data on PCC servers",
                                "Your data is not retained after a request completes",
                                "Your data is never used to train Apple models",
                                "PCC requests are cryptographically verifiable by security researchers",
                            ])
                        }
                        PPSubsection(title: "3.3 No Third-Party AI") {
                            PPBody("Textifyr does not send your data to OpenAI, Google, Anthropic, Microsoft, or any other third-party AI service. All AI processing goes exclusively through Apple's Foundation Models infrastructure.")
                        }
                        PPSubsection(title: "3.4 AI Accuracy") {
                            PPBody("AI-generated content may be inaccurate, incomplete, or misleading. Textifyr AI output should not be used for medical, legal, financial, safety-critical, or other high-stakes decisions without independent verification.")
                        }
                    }

                    // 4. iCloud Sync
                    PPSection(number: 4, title: "iCloud Sync") {
                        PPBody("If you are signed into iCloud on your Mac, Textifyr optionally syncs your documents, transcripts, pipelines, and settings via Apple CloudKit.")
                        PPBullets([
                            "Your data is stored in your private CloudKit database — accessible only to you",
                            "Textifyr uses end-to-end encryption for synced data where supported by CloudKit",
                            "The developer has no access to your CloudKit data",
                        ])
                        PPBody("To disable iCloud sync: System Settings → Apple ID → iCloud → Apps Using iCloud → disable Textifyr.")
                    }

                    // 5. System Permissions
                    PPSection(number: 5, title: "System Permissions") {
                        PPBody("Textifyr requests the following macOS permissions. Each is requested only at the moment you use the relevant feature, not at app launch.")
                        PPTable(rows: [
                            ("Microphone", "Live transcription and audio file import"),
                            ("Camera", "Capture and OCR of a camera photo"),
                            ("Photo Library", "Select a photo for OCR"),
                            ("Screen Recording", "Capture and OCR of your display"),
                        ])
                        PPBody("You can review and revoke these permissions at any time in System Settings → Privacy & Security.")
                    }

                    // 6. Data Retention
                    PPSection(number: 6, title: "Data Retention and Deletion") {
                        PPSubsection(title: "6.1 Local data") {
                            PPBody("All Textifyr data stored locally is under your direct control. To delete it:")
                            PPBullets([
                                "Individual documents: Select the document in the sidebar and tap the − button",
                                "All data: Delete Textifyr and its associated data in System Settings → General → Storage, or delete the SwiftData store at ~/Library/Application Support/Textifyr/",
                            ])
                        }
                        PPSubsection(title: "6.2 iCloud data") {
                            PPBody("Disabling iCloud sync stops future sync. Previously synced data in iCloud can be deleted by deleting the corresponding documents in Textifyr while sync is still enabled, then disabling sync. You can also clear all iCloud data for Textifyr at iCloud.com → Manage Storage → Textifyr.")
                        }
                        PPSubsection(title: "6.3 Temporary processing data") {
                            PPBody("Audio recordings, camera captures, and screen captures used for transcription or OCR are held in memory only during processing and discarded immediately afterward. They are never written to disk unless you explicitly save the result.")
                        }
                    }

                    // 7–11
                    PPSection(number: 7, title: "Children's Privacy") {
                        PPBody("Textifyr is not directed at children under 13. We do not knowingly collect personal information from children. If you believe a child has provided personal information through this app, please contact us and we will take steps to delete it.")
                    }

                    PPSection(number: 8, title: "Security") {
                        PPBullets([
                            "All data stored locally is protected by macOS file system encryption (FileVault)",
                            "iCloud data is encrypted in transit and at rest by Apple",
                            "Textifyr does not implement any network servers, APIs, or backend infrastructure",
                            "No data is stored outside your device and your personal iCloud account",
                        ])
                    }

                    PPSection(number: 9, title: "Changes to This Policy") {
                        PPBody("If this privacy policy changes materially, Textifyr will notify you with an in-app prompt on the next launch. The effective date at the top of this document will be updated. Continued use of the app after notification constitutes acceptance of the revised policy.")
                    }

                    PPSection(number: 10, title: "Contact") {
                        PPBody("If you have questions about this privacy policy or Textifyr's data practices, please contact the developer via the support link in the App Store listing.")
                    }

                    PPSection(number: 11, title: "Applicable Law") {
                        PPBody("This policy is governed by the laws of your jurisdiction. Textifyr is published on the Apple App Store and is subject to Apple's App Store Review Guidelines and Apple Media Services Terms and Conditions.")
                    }

                    Text("This privacy policy was prepared in accordance with Apple App Store Review Guidelines §5.1 (Privacy) and the Foundation Models Framework Acceptable Use Requirements.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
                .padding(24)
            }
        }
        .frame(width: 680, height: 640)
    }
}

// MARK: - Building blocks

private struct PPSection<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(number). \(title)")
                .font(.title3.bold())
            content()
        }
    }
}

private struct PPSubsection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .padding(.top, 4)
            content()
        }
    }
}

private struct PPBody: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PPCallout: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PPBullets: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("·")
                        .foregroundStyle(.secondary)
                        .font(.body)
                    Text(item)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct PPTable: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Data type")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
                Text("What it contains")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top, spacing: 0) {
                    Text(row.0)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    Divider()
                    Text(row.1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .background(index.isMultiple(of: 2) ? Color.clear : Color(NSColor.controlBackgroundColor).opacity(0.4))
                if index < rows.count - 1 { Divider() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}

#Preview {
    PrivacyPolicyView()
}
