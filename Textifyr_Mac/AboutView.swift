import SwiftUI

struct AboutView: View {
    @State private var showPrivacyPolicy = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Icon + identity
            VStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                }
                Text("Textifyr")
                    .font(.largeTitle.bold())
                Text("Version \(appVersion) (\(buildNumber))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
            .padding(.bottom, 20)

            // Description
            Text("Capture text from your voice, audio, video, camera, photos, PDFs, and the web. Format and summarise with Apple Intelligence — everything processed on your device.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)

            Divider()
                .padding(.vertical, 20)

            // Acknowledgements
            VStack(alignment: .leading, spacing: 12) {
                Text("Acknowledgements")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)

                AcknowledgementRow(
                    name: "SpeakerKit",
                    author: "argmax, inc.",
                    license: "MIT",
                    url: "https://github.com/argmaxinc/argmax-oss-swift",
                    notice: """
                        MIT License

                        Copyright (c) 2024 argmax, inc.

                        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

                        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

                        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
                        """
                )
            }
            .padding(.horizontal, 28)

            Divider()
                .padding(.vertical, 20)

            // Footer
            VStack(spacing: 8) {
                Text("© 2026 Textifyr. All rights reserved.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button("Privacy Policy") {
                    showPrivacyPolicy = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(.bottom, 28)
        }
        .frame(width: 460)
        .sheet(isPresented: $showPrivacyPolicy) {
            PrivacyPolicyView()
        }
    }
}

// MARK: - Acknowledgement row

private struct AcknowledgementRow: View {
    let name: String
    let author: String
    let license: String
    let url: String
    let notice: String

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body.bold())
                    Text("by \(author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(license)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
                Button(expanded ? "Hide" : "License") {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            if expanded {
                ScrollView {
                    Text(notice)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 140)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                )
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    AboutView()
}
