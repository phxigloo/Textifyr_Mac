import SwiftUI

// MARK: - Help topic model

struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let content: HelpContent

    static func == (lhs: HelpTopic, rhs: HelpTopic) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HelpContent {
    let sections: [HelpSection]
}

struct HelpSection: Identifiable {
    let id = UUID()
    let heading: String?
    let body: String
}

// MARK: - Help window

struct HelpWindowView: View {
    @State private var selectedTopicID: String? = helpTopics.first?.id

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let id = selectedTopicID, let topic = helpTopics.first(where: { $0.id == id }) {
                HelpDetailView(topic: topic)
            } else {
                Text("Select a topic")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        List(helpTopics, selection: $selectedTopicID) { topic in
            Label(topic.title, systemImage: topic.icon)
                .tag(topic.id)
        }
        .navigationTitle("Textifyr Help")
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    }
}

// MARK: - Detail view

private struct HelpDetailView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: topic.icon)
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                    Text(topic.title)
                        .font(.largeTitle.bold())
                }
                .padding(.bottom, 4)

                ForEach(topic.content.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if let heading = section.heading {
                            Text(heading)
                                .font(.headline)
                        }
                        Text(section.body)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Topic definitions

let helpTopics: [HelpTopic] = [
    HelpTopic(
        id: "getting-started",
        title: "Getting Started",
        icon: "sparkles",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "Textifyr turns captured audio, images, and text into polished documents using Apple Intelligence — all processed on your device."),
            HelpSection(heading: "The basic workflow",
                body: "1. Create a new document.\n2. Add one or more Sources (transcripts, photos, files).\n3. Optionally refine each source with a Before Combining action.\n4. Choose a Final Document action and tap Format.\n5. Review and export your finished document."),
            HelpSection(heading: "Documents",
                body: "Each document has its own Sources and output. Use the sidebar to switch between documents, or tap + to create a new one."),
        ])
    ),
    HelpTopic(
        id: "sources",
        title: "Sources",
        icon: "waveform.and.mic",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "A source is any piece of text or image that contributes to your final document. You can mix and match different source types in the same document."),
            HelpSection(heading: "Source types",
                body: "• Microphone — records live audio and transcribes it.\n• Audio File — imports a pre-recorded audio file.\n• Camera / Photo Library — takes or selects a photo and runs OCR.\n• Image File — imports an image and runs OCR.\n• Embed Image — embeds a picture in the output without extracting text.\n• Screen Capture — captures your screen and runs OCR.\n• Apple Intelligence — lets you dictate or type text and enhance it with AI.\n• Web — imports text from a web address.\n• PDF — imports a PDF document.\n• Rich Text — pastes or types formatted text directly."),
            HelpSection(heading: "Ordering sources",
                body: "Sources are combined in the order shown. Drag rows to reorder them."),
            HelpSection(heading: "Editing a source",
                body: "Tap any source row to open the editor. For text sources you can manually edit the transcript, run Before Combining actions, or chat with Apple Intelligence about the content. For Embed Image sources you can change the processing settings and caption."),
        ])
    ),
    HelpTopic(
        id: "after-capture",
        title: "After Capture Actions",
        icon: "wand.and.stars",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "After Capture actions run automatically immediately after a new source is captured. They are ideal for clean-up tasks that every transcript needs — removing filler words, fixing punctuation, or formatting numbers."),
            HelpSection(heading: "Setting a default",
                body: "In Settings → AI Actions, choose a default After Capture action. It applies to all new captures. You can override per-source in the Action Editor."),
            HelpSection(heading: "Creating your own",
                body: "Open Tools → Action Editor, tap +, and set the scope to After Capture. Write a system prompt that describes the clean-up task. Each step runs sequentially, which lets you chain multiple transformations."),
        ])
    ),
    HelpTopic(
        id: "before-combining",
        title: "Before Combining Actions",
        icon: "arrow.triangle.merge",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "Before Combining actions run on a single source's transcript before it is merged with other sources. Use them to reformat, summarise, or expand a particular source without affecting the others."),
            HelpSection(heading: "Running an action",
                body: "Open a source, switch to the Chat tab, and tap an action button in the action bar. The result appears as a bubble — tap Use This to replace the transcript, or dismiss it to keep the original."),
            HelpSection(heading: "Freeform prompt",
                body: "The Process tab also has a Freeform AI Prompt option. Expand it to type any instruction and send it to Apple Intelligence. The result appears as a bubble identical to an action result, so you can review it before applying."),
            HelpSection(heading: "Undo",
                body: "Replacing the transcript saves the previous version. Tap the ↩ Undo Replace button in the toolbar to restore up to 20 previous versions."),
        ])
    ),
    HelpTopic(
        id: "final-document",
        title: "Final Document Actions",
        icon: "doc.text.fill",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "A Final Document action runs on the combined text of all sources and produces the finished output — meeting minutes, lecture notes, a structured report, etc."),
            HelpSection(heading: "Selecting an action",
                body: "In the Output pane, open the action menu (⚡ icon) and choose an action. Tap Format to run it. The output appears as editable rich text."),
            HelpSection(heading: "Large documents",
                body: "If your combined source text is very long, Textifyr splits it into chunks and processes each chunk in sequence, then merges the results. This is noted in the progress indicator."),
            HelpSection(heading: "Exporting",
                body: "Once you have output, tap Export to save as RTF, plain text, or another format. Embedded images are included in the RTF export."),
        ])
    ),
    HelpTopic(
        id: "prompt-builder",
        title: "Prompt Builder",
        icon: "text.badge.plus",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "The Prompt Builder (Tools → Prompt Builder, or ⌘⇧P) helps you design and test AI action prompts interactively."),
            HelpSection(heading: "Testing prompts",
                body: "Paste sample text in the Source field, write a system prompt, and tap Run to see the result. Adjust the prompt and re-run until you're happy with the output."),
            HelpSection(heading: "Saving to an action",
                body: "Tap Save to Action to add the prompt as a new step in an existing action, or to create a new action. You can choose the scope (After Capture, Before Combining, or Final Document) at save time."),
        ])
    ),
    HelpTopic(
        id: "keyboard-shortcuts",
        title: "Keyboard Shortcuts",
        icon: "keyboard",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "Commonly used shortcuts in Textifyr:"),
            HelpSection(heading: "Documents",
                body: "⌘N — New document"),
            HelpSection(heading: "Tools",
                body: "⌘⇧P — Open Prompt Builder\n⌘⇧E — Open Action Editor"),
        ])
    ),
    HelpTopic(
        id: "tips-limitations",
        title: "Tips & Limitations",
        icon: "lightbulb",
        content: HelpContent(sections: [
            HelpSection(heading: "Context window",
                body: "Apple Intelligence has a limited context window. Very long transcripts are automatically chunked, but extremely detailed instructions combined with large inputs may produce inconsistent results. Keeping actions focused on a single task produces the best output."),
            HelpSection(heading: "AI availability",
                body: "All AI features require Apple Intelligence to be enabled on your device (System Settings → Apple Intelligence & Siri). If AI features are unavailable, you can still capture and export plain-text transcripts."),
            HelpSection(heading: "Audio quality",
                body: "Transcription accuracy depends on audio quality. A quiet environment, a close microphone, and clear speech significantly improve results. The speaker identification feature works best with 2–4 distinct voices."),
            HelpSection(heading: "Image OCR",
                body: "OCR accuracy is best with high-contrast, well-lit images. For handwritten text, use the Handwriting / Sketch category in the Embed Image wizard to help Apple Intelligence interpret the content."),
        ])
    ),
    HelpTopic(
        id: "privacy",
        title: "Privacy",
        icon: "lock.shield",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "Textifyr is designed with privacy as a priority."),
            HelpSection(heading: "On-device processing",
                body: "All AI processing uses Apple Intelligence, which runs entirely on your device. Your transcripts, documents, and images are never sent to Anthropic or any third-party server."),
            HelpSection(heading: "Local storage",
                body: "All documents and source sessions are stored in SwiftData on your Mac. Textifyr does not sync data externally unless you use iCloud Drive and have enabled it in System Settings."),
            HelpSection(heading: "Microphone and camera",
                body: "Textifyr requests microphone access for live recording and camera access for the Embed Image wizard. Access can be revoked at any time in System Settings → Privacy & Security."),
        ])
    ),
]

#Preview {
    HelpWindowView()
        .frame(width: 820, height: 600)
}
