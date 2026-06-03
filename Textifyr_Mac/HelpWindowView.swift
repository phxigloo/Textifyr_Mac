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
        id: "splitting",
        title: "Splitting a Source",
        icon: "scissors",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "The Splitter is a tool that cuts a long piece of text into smaller pieces. Each piece becomes its own source. This matters because the AI can only read a certain amount of text at one time — like reading one chapter of a book instead of the whole thing at once. Smaller, focused pieces give the AI a better chance of doing a great job."),

            HelpSection(heading: "When should I split?",
                body: "A warning appears in the source review screen when your text is very long. It tells you roughly how many chunks the AI will need. If that number is larger than 4 or 5, splitting first usually gives better results. You choose where to make the cuts.\n\nYou can also split any time you want to keep different topics or sections as separate sources — for example, splitting a long meeting into one source per agenda item."),

            HelpSection(heading: "How to open the Splitter",
                body: "In the source review screen, tap the Split Now button that appears below the large-text warning. The Splitter window opens."),

            HelpSection(heading: "The two panels",
                body: "The Splitter window has two panels side by side.\n\nLeft panel — the Part list. This shows each section (called a Part) after you add splits. Every row shows a coloured dot, the name Part 1, Part 2, and so on, and how many characters are in that Part. If a Part is too long, an orange warning triangle appears. Hover over the triangle to see exactly how long it is and what the limit is. Tap any row to jump to that Part in the text panel.\n\nRight panel — the text. This shows all your text at once. Each Part is highlighted in its own colour so you can see at a glance where one Part ends and the next begins. Between every two paragraphs or sentences there is a thin line — that is where you can add a split."),

            HelpSection(heading: "Adding a split by hand",
                body: "Move your mouse over any thin line between two paragraphs. The line lights up and shows a prompt to split here. Click it and a solid blue line appears — that is your confirmed split point. The text on either side is now shown in different colours in the Part list.\n\nTo remove a split, click the blue line again. It disappears and the two Parts merge back into one."),

            HelpSection(heading: "Setting a maximum size — Set Max",
                body: "Click Set max at the top of the window. A counter appears. Use the + and − buttons to choose a target size in characters — for example, 4,000. Textifyr immediately calculates where to cut and shows orange dotted lines at the suggested split points.\n\nThe counter remembers the number you chose last time, so you do not have to type it in again the next time you open the Splitter."),

            HelpSection(heading: "Suggested splits",
                body: "Orange dotted lines are suggestions — Textifyr has worked out where to cut so that each Part stays at or under your chosen size. You have three choices:\n\n• Click any individual orange line to accept just that one cut. It turns blue.\n• Tap Accept Suggested at the bottom of the window to accept all orange suggestions at once.\n• Tap Accept All Splits to split at every single paragraph and sentence boundary — this gives you the maximum number of Parts.\n\nYou can always click a blue line to remove a split you do not want, even after accepting suggestions."),

            HelpSection(heading: "Searching the text",
                body: "At the top of the right panel there is a search box. Type any word or phrase to find it in your text. Paragraphs that match are highlighted in yellow. Use the arrow buttons to jump between matches.\n\nThis is handy when you want to split near a specific part of the text — for example, the start of a new topic or the beginning of a different speaker\'s turn."),

            HelpSection(heading: "Confirming your splits",
                body: "When you are happy with your split points, tap Confirm Split at the bottom right. The Splitter closes and each Part becomes its own source in your document. The original long source is replaced by two or more shorter ones, each of which you can work with independently.\n\nTap Cancel at any time to close the Splitter without making any changes. Nothing in your document is affected."),

            HelpSection(heading: "When text has no paragraph breaks",
                body: "Some text arrives as one solid block with no paragraph or sentence breaks — this is called a text wall. The Splitter detects this and shows a simpler screen. Use the + and − buttons to choose how many Parts you want. A short preview shows the start of each Part so you can check the cuts make sense. Tap Confirm Split when you are ready."),

            HelpSection(heading: "Tips for best results",
                body: "• A good size for most AI tasks is 4,000 to 10,000 characters per Part. Smaller is not always better — splitting too finely means the AI loses the thread between Parts.\n• If a Part still has a warning triangle after you have added all your splits, it means that single sentence is already longer than your limit on its own. The AI will still process it — it just may be a little slower.\n• Splitting by topic or section (one idea per Part) often works better than splitting purely by size. The AI responds well when each Part has a clear focus.\n• After splitting, you can run a Before Combining action on each Part individually — useful for cleaning up or summarising each section separately before the final document is created."),
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
        id: "how-ai-works",
        title: "How the AI Works",
        icon: "brain.head.profile",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "Textifyr uses Apple Intelligence — an AI built into your Mac by Apple. Most processing happens directly on your device. For more complex tasks, Apple may use Private Cloud Compute — Apple-run servers that are private, secure, retain no data, and whose code is publicly verifiable. Your text is never sent to Anthropic or any other third-party. Here's what you need to know to get the best results."),

            HelpSection(heading: "What the AI actually does",
                body: "• You give it an instruction (called a prompt). It follows the instruction and returns a result.\n• It reads text in, writes text out — that's it.\n• It can clean up grammar, summarise, translate, reformat, remove filler words — whatever your prompt asks.\n• It does not browse the internet or remember previous documents."),

            HelpSection(heading: "Tokens — not characters",
                body: "• The AI doesn't count characters. It works in pieces called tokens.\n• One token is roughly 4 characters, or about ¾ of a word.\n• Example: \"Hello world\" ≈ 2 tokens. A Shakespeare play (100,000 characters) ≈ 25,000 tokens.\n• Why does this matter? The AI can only hold a limited number of tokens in memory at one time."),

            HelpSection(heading: "The context window — AI's short-term memory",
                body: "• The AI can only \"see\" about 16,000 characters at a time. This limit is called the context window.\n• Think of it like a sticky note. If your text is too long to fit on the sticky note, the AI can't read the whole thing at once.\n• Your prompt AND your text both have to share that sticky note — so a long prompt leaves less room for text.\n• Textifyr works around this automatically using chunking (see below)."),

            HelpSection(heading: "Your text is added automatically",
                body: "• When you write a prompt like \"Summarise this\", Textifyr automatically adds your transcript to the message before sending it to the AI.\n• You only write the instruction. Textifyr handles the rest.\n• This is why the context window matters — every time the AI runs, your prompt takes up part of that 16,000-character limit."),

            HelpSection(heading: "Chunking — how large text is handled",
                body: "• When your text is too big to fit in one go, Textifyr automatically splits it into pieces called chunks.\n• Each chunk is processed separately, then all the results are joined together.\n• You'll see \"Part 1 of 14\" in the progress bar when this is happening.\n• Chunk size is calculated automatically — a longer prompt means smaller chunks, because the prompt takes up more of the sticky note."),

            HelpSection(heading: "What chunking is great at",
                body: "These tasks work perfectly because each piece of text can be handled on its own:\n• Fixing grammar and punctuation\n• Removing filler words\n• Translating to another language\n• Reformatting or restructuring paragraphs\n• Cleaning up a transcript"),

            HelpSection(heading: "What chunking can't do",
                body: "These tasks need to see the whole document at once — chunking can't help:\n• Writing one unified summary of a very long document — you'll get 14 mini-summaries joined together, not one paragraph.\n• \"List all characters in this play\" — each chunk only sees its own section, so the lists won't combine.\n• Any task that requires understanding the full story or context from start to finish.\n\nFix: Use a two-step action. Step 1: \"Summarise this section\" (runs chunked, produces 14 mini-summaries). Step 2: \"Combine these summaries into one\" (the combined mini-summaries are now short enough to fit in one context window)."),

            HelpSection(heading: "Tips for best results",
                body: "• Keep prompts focused on one task. \"Fix grammar and remove filler words\" works better than five instructions crammed into one prompt.\n• For very long documents, multi-step actions give more consistent results — one clear task per step.\n• If the AI seems to ignore part of your instruction, your prompt may be too long — try shortening it.\n• If the output looks cut off, the source text may have been very long — try splitting it into smaller sources.\n• The AI sometimes adds unwanted phrases like \"Sure, here's the result…\" — Textifyr strips these automatically."),
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
            HelpSection(heading: "On-device and Private Cloud Compute",
                body: "Apple Intelligence processes most tasks directly on your device using its built-in AI models. For more complex requests, your Mac may send the task to Apple's Private Cloud Compute — Apple-run servers built on Apple Silicon.\n\nPrivate Cloud Compute is designed with strong privacy guarantees:\n• Your data is used only to complete the task and is not retained afterwards.\n• Apple cannot inspect the content of your requests.\n• The server software is published so independent security researchers can verify these claims.\n\nYour transcripts, documents, and images are never sent to Anthropic or any other third-party service. The decision to use on-device or cloud processing is made automatically by Apple Intelligence based on the complexity of the task."),
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
