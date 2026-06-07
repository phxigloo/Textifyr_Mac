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
    let uiViews: [HelpUIView]
    init(sections: [HelpSection] = [], uiViews: [HelpUIView] = []) {
        self.sections = sections
        self.uiViews = uiViews
    }
}

struct HelpSection: Identifiable {
    let id = UUID()
    let heading: String?
    let body: String
}

struct HelpUIView: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let function: String
    let howItWorks: String
    let appFlow: String
    let buttons: String
    let tips: String
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

                if !topic.content.uiViews.isEmpty {
                    ForEach(topic.content.uiViews) { view in
                        HelpUIViewRow(entry: view)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct HelpUIViewRow: View {
    let entry: HelpUIView
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                uiSection("Purpose", body: entry.function)
                uiSection("How it works", body: entry.howItWorks)
                uiSection("Where it fits", body: entry.appFlow)
                uiSection("Controls & buttons", body: entry.buttons)
                uiSection("Tips", body: entry.tips)
            }
            .padding(.top, 10)
            .padding(.leading, 4)
        } label: {
            Label(entry.name, systemImage: entry.icon)
                .font(.headline)
        }
        .padding(.vertical, 6)
        Divider()
    }

    private func uiSection(_ heading: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        id: "user-interface",
        title: "User Interface",
        icon: "rectangle.on.rectangle",
        content: HelpContent(
            sections: [
                HelpSection(heading: nil,
                    body: "Tap any view below to learn what it does, how to use it, and how it connects to the rest of Textifyr."),
            ],
            uiViews: [
                HelpUIView(
                    name: "Main Window",
                    icon: "doc.richtext",
                    function: "The main window is your document workspace. It shows all your open documents in a sidebar on the left, the source list for the selected document in the centre, and the formatted output on the right.",
                    howItWorks: "Each document holds one or more Sources — pieces of captured text or images. When you run a Final Document action, all sources are combined and processed by Apple Intelligence to produce the formatted output shown on the right side of the window.",
                    appFlow: "The main window is the hub of Textifyr. You start here to create documents and add sources. Sources feed into the Action Editor (for custom formatting) and the output is exported from here. The sidebar and inspector panels can be shown or hidden using the View menu.",
                    buttons: "• + (toolbar) — Creates a new document.\n• Sources button — Opens the source picker to add a new source.\n• Format (⌘R) — Runs the selected Final Document action on all sources.\n• Export (⌘⇧S) — Opens the export sheet to save the output.\n• Show/Hide Sidebar — Toggles the document list on the left.\n• Show/Hide Inspector — Toggles the action inspector panel on the right.\n• Stage badge — Tap on a source row's stage badge to change its workflow stage.",
                    tips: "• Drag sources up and down in the list to change the order they are combined.\n• You can have multiple document windows open — use ⌘N to create a new one.\n• The Inspector on the right lets you assign Before Combining actions to each source without opening the Action Editor."
                ),
                HelpUIView(
                    name: "Source Detail",
                    icon: "waveform.and.mic",
                    function: "The Source Detail view opens when you tap any source row. It shows the captured transcript or image content, lets you edit it, and provides tools to run Before Combining actions or chat with Apple Intelligence about the content.",
                    howItWorks: "Source Detail has two tabs: Text (the transcript) and the action bar at the bottom. You can manually edit the transcript in the text area. Running a Before Combining action sends the transcript to Apple Intelligence and displays the result as a bubble — tap Use This to apply it, or dismiss to keep the original.",
                    appFlow: "Source Detail sits between capture and the final document. After a source is captured and auto-cleaned (After Capture action), you use Source Detail to apply per-source formatting before the sources are combined. Changes made here only affect this source — not others in the same document.",
                    buttons: "• Edit area — Click directly in the transcript to make manual edits.\n• Action bar — Buttons for each Before Combining action assigned to this source. Tap one to run it.\n• Undo Replace (↩) — Restores the previous transcript. Available after applying an action result.\n• Split — Opens the Splitter if the transcript is very long.\n• Freeform Prompt — Expand to type a custom instruction and send it to Apple Intelligence.",
                    tips: "• You can run multiple actions in sequence — each one starts from the current transcript.\n• Use Undo Replace to compare different action results before committing to one.\n• Long transcripts automatically show a character count warning. Use Split to break them into smaller sources before running actions."
                ),
                HelpUIView(
                    name: "Action Editor",
                    icon: "wand.and.stars",
                    function: "The Action Editor (Tools → Action Editor, ⌘⇧E) is where you create, edit, and organise AI formatting actions. An action is a named sequence of one or more steps, each with its own AI prompt.",
                    howItWorks: "Actions are organised into three scopes: After Capture (runs automatically after any source is captured), Before Combining (run manually on a single source), and Final Document (runs on all sources combined). Each action can have multiple steps that run in sequence. You can copy steps from other actions, reorder them by dragging, and hide built-in actions you don't use.",
                    appFlow: "Actions created in the Action Editor become available throughout the app — in the source detail action bar, in the output pane's action menu, and in the Auto Cleanup settings. The Action Editor is the central place to manage all your AI formatting instructions. When you write a new prompt in the Prompt Builder and save it, it is saved here as a new action step.",
                    buttons: "• + (footer) — Adds a new action in the selected scope.\n• − (footer) — Deletes the selected action (custom actions only; built-in actions can only be hidden).\n• Show hidden toggle — Reveals built-in actions that have been hidden.\n• Add Step (action detail) — Adds a new prompt step to the selected action.\n• Copy Step from Pipeline — Opens a sheet to copy a step from any other action.\n• Save (⌘S) — Saves unsaved changes. A confirmation dialog appears if you try to navigate away with unsaved changes.\n• Discard — Reverts all unsaved changes to the selected action.\n• Run (step detail) — Tests the step's prompt against the built-in sample text.\n• Prompt Builder (step detail) — Opens the Prompt Builder pre-loaded with this step's prompt.",
                    tips: "• Use sequential steps for complex tasks: one step to clean up grammar, another to restructure, another to add a summary. Each step's output becomes the next step's input.\n• Give actions descriptive names — they appear as buttons in Source Detail and in the output pane action menu.\n• The After Capture scope is best for light clean-up (filler words, basic punctuation). Save heavy formatting for Before Combining or Final Document where you have more control."
                ),
                HelpUIView(
                    name: "Prompt Builder",
                    icon: "text.badge.plus",
                    function: "The Prompt Builder (Tools → Prompt Builder, ⌘⇧P) is an interactive workspace for writing and testing AI prompts. You write a prompt, run it against sample text, and refine it until the output is exactly right — then save it to an action.",
                    howItWorks: "The Prompt Builder has three columns: Samples (on the left), the Sample Work Area (centre), and the Prompt editor (right). Select a built-in sample or create your own, write a prompt in the right-hand panel, and click Run to see what Apple Intelligence produces. The AI Improvement chat panel slides in from the right to help you refine the prompt through conversation.",
                    appFlow: "The Prompt Builder is the development environment for your AI prompts. You use it to design and test prompts before saving them to an action step in the Action Editor. It sits outside the main document workflow — changes here do not affect any document until you explicitly save to an action.",
                    buttons: "• Run ▶ (bottom-right) — Sends the current prompt and sample text to Apple Intelligence and shows the result.\n• Stop — Cancels a running prompt.\n• Load from Action… — Loads an existing action step's prompt into the editor.\n• Save to Action… — Saves the current prompt as a new step in an existing action, or creates a new action.\n• Clear (prompt) — Clears the prompt text.\n• wand.and.sparkles (prompt header) — Opens the AI Improvement chat panel.\n• + (Samples) — Adds a new blank sample.\n• − (Samples) — Deletes the selected sample.\n• Scratchpad — A temporary text area for pasting in real-world text. Not saved.\n• Save / Discard (sample editing) — Appears when you have edited a saved sample's name, scope, or text. Changes are not auto-saved.\n• Use as Prompt ↗ (chat bubble) — Applies an AI-suggested prompt directly to the prompt editor.\n• New Conversation (chat) — Clears the chat history and starts fresh with updated context.",
                    tips: "• Start with a built-in sample that resembles your real-world source text — this gives you a realistic test environment.\n• Use the Scratchpad for one-off testing with text you've pasted from elsewhere. It is not saved between sessions.\n• In the AI Improvement chat, describe what you expected vs. what you got — the AI will suggest a revised prompt. Use 'Use as Prompt ↗' to apply it instantly.\n• Save the Scope when creating a sample — it controls which actions are visible when you use Load from Action."
                ),
                HelpUIView(
                    name: "Settings",
                    icon: "gearshape",
                    function: "Settings (⌘,) is where you configure Textifyr's global behaviour: AI privacy options, network access, filler word lists, find & replace rules, workflow stages, and window management.",
                    howItWorks: "Settings is divided into four tabs: General (AI and privacy options), Text Processing (filler words, cleanup rules, default action), Stages (workflow stage management), and Windows (document window limits and quick links to the Action Editor and Prompt Builder).",
                    appFlow: "Settings affects the entire app. Changes take effect immediately — there is no Save button. The Text Processing tab controls what happens automatically when a source is captured (filler word removal, cleanup rules). The Stages tab defines the stage badges you see on source rows in the main window.",
                    buttons: "• Show AI Privacy Notice Again — Resets the privacy warning so it appears before the next AI operation.\n• Block web requests toggle — Prevents the Web URL source from making network calls.\n• Maximum open documents stepper — Controls how many document windows can be open at once.\n• Filler word Add button — Adds a word to your custom filler word list.\n• Find & Replace Add button — Adds a text substitution rule applied during auto-cleanup.\n• Default Final Document picker — Sets which action runs automatically on new documents.\n• Add Stage / Edit / Delete — Manage the workflow stages available throughout the app.\n• Open Action Editor… — Opens the Action Editor directly from Settings.\n• Open Prompt Builder… — Opens the Prompt Builder directly from Settings.\n• View Privacy Policy — Shows the full privacy policy.\n• Reset and Show Disclaimer — Clears term acceptance and forces the disclaimer on next launch.",
                    tips: "• Filler word removal runs before any AI action — removing words like 'um' and 'uh' makes the AI's job easier and improves output quality.\n• Keep the Maximum open documents setting low (2–3) if your Mac has limited RAM — each document window holds its sources and output in memory.\n• Custom find & replace rules are powerful for fixing recurring transcription errors. For example, if your microphone always transcribes your name incorrectly, add a rule to fix it automatically."
                ),
                HelpUIView(
                    name: "Sources Tab",
                    icon: "tray.2",
                    function: "The Sources Tab (in the main window sidebar) shows the complete list of source sessions across all documents. It is a library view — you can browse, search, and review past captures without having to navigate into each document.",
                    howItWorks: "Sources are listed with their type icon, date, and a preview of the captured text or image. Tapping a source opens its detail view. The search bar at the top filters by text content across all sources.",
                    appFlow: "The Sources Tab provides a cross-document view of everything that has been captured. It is most useful when you want to find a past capture and add it to a new document, or review what was captured during a session without opening the document.",
                    buttons: "• Search bar — Filters the source list by text content.\n• Source row — Tap to open the source in its detail view.\n• + (toolbar) — Adds a new source using the source picker.",
                    tips: "• Use the Sources Tab to find old captures quickly — it is faster than opening each document individually.\n• The search bar searches the full text of each transcript, not just the title."
                ),
                HelpUIView(
                    name: "Help Window",
                    icon: "questionmark.circle",
                    function: "The Help Window (Help → Textifyr Help, ⌘?) provides in-app documentation covering all features. It is organised into topics in a sidebar, with detailed content on the right.",
                    howItWorks: "Select a topic in the left sidebar to read its content on the right. Topics are self-contained — you can read them in any order. The User Interface section (this page) has collapsible entries for each view — click any heading to expand or collapse its content.",
                    appFlow: "The Help Window is independent of the main workflow — opening it does not affect any document or capture. It can stay open alongside other windows. It is the first place to check if something is not working as expected, especially the Troubleshooting topic.",
                    buttons: "• Sidebar topics — Click any topic to navigate to it.\n• Disclosure triangles (User Interface) — Click to expand or collapse each view's documentation.\n• Resize handle — Drag the divider between the sidebar and content to adjust their widths.",
                    tips: "• The Troubleshooting topic explains the most common errors, including the content filter warning.\n• How the AI Works explains context windows and chunking — understanding this helps you write better prompts."
                ),
            ]
        )
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
                body: "All keyboard shortcuts in Textifyr. Shortcuts marked * are standard macOS shortcuts provided by the system."),
            HelpSection(heading: "File",
                body: "⌘N — New Document\n⌘⇧S — Export…\n⌘P — Print…"),
            HelpSection(heading: "Edit",
                body: "⌘Z — Undo *\n⌘⇧Z — Redo *\n⌘X — Cut *\n⌘C — Copy *\n⌘V — Paste *\n⌘A — Select All *\n⌘F — Find & Replace"),
            HelpSection(heading: "Format",
                body: "⌘B — Bold\n⌘I — Italic\n⌘U — Underline\n⌘+ — Bigger\n⌘- — Smaller\n⌘{ — Align Left\n⌘| — Align Center\n⌘} — Align Right\n⌘T — Fonts Panel"),
            HelpSection(heading: "Tools",
                body: "⌘R — Format Document\n⌘⇧P — Prompt Builder\n⌘⇧E — Action Editor\n⌘1 — Open Main Window\n⌘, — Settings"),
            HelpSection(heading: "Sources",
                body: "⌘⌥I — AI Writer\n⌘⌥S — Screen Capture\n⌘⌥M — Microphone\n⌘⌥A — Audio File\n⌘⌥V — Video Audio\n⌘⌥C — Camera\n⌘⌥P — Photo Library\n⌘⌥O — Image (OCR)\n⌘⌥T — Text Editor\n⌘⌥D — PDF\n⌘⌥W — Web URL\n⌘⌥E — Embed Image"),
            HelpSection(heading: "Action Editor",
                body: "⌘S — Save changes\n(These shortcuts are active only while the Action Editor is open.)"),
            HelpSection(heading: "Help",
                body: "⌘? — Open this help window"),
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
        id: "sharing",
        title: "Sharing & Dropping Files",
        icon: "square.and.arrow.up",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "Textifyr appears in the system Share menu. From most apps and from the Finder, select an item, click the Share button (or right-click → Share), and choose \"Add to Textifyr\". A small panel lets you pick a new or recent document and, for images, whether to extract text or embed the picture. The content is added to Textifyr — click \"Open Textifyr\" to view it."),
            HelpSection(heading: "Drag and drop",
                body: "You can also drag files straight into Textifyr — the same file types listed below are supported:\n• Onto the document list (left sidebar) — creates a new document from the dropped file(s). Dropping several at once puts them all in one new document.\n• Onto the Sources area of an open document — adds the file(s) as sources to that document.\n• Onto the Output of an open document — inserts the file's content into the document where you drop it: text files insert their text, and images insert their OCR text or the picture itself.\n• Onto the Textifyr icon in the Dock — creates a new document from the dropped file(s).\n\nWhen a drop includes image files, Textifyr asks once whether to extract their text (OCR) or embed the pictures, and applies your choice to all images in that drop. Dropped audio and video open in the transcription wizard. If you drop several files at once they are handled one at a time, and any that need a wizard wait their turn — so dropping five recordings walks you through five transcriptions in order."),
            HelpSection(heading: "What you can share",
                body: "• Selected text — added as a Rich Text source.\n• Web pages — share a link and Textifyr imports the readable text.\n• Images (PNG, JPEG, HEIC, TIFF, GIF, BMP) — choose Extract Text (OCR) to pull out the words, or Embed Image to place the picture in your document.\n• Screenshots — share from the screenshot thumbnail or the Finder.\n• PDFs — text is extracted automatically; scanned PDFs are run through OCR.\n• Plain text, RTF, CSV, and TSV files — imported as a Rich Text source.\n• Audio and video files (M4A, MP3, WAV, AIFF, MOV, MP4) — handed to the transcription wizard, which transcribes them automatically."),
            HelpSection(heading: "Best results from the Finder",
                body: "Sharing the actual file from the Finder is the most reliable path. Some apps share a reference to what they are showing rather than the underlying file — for example, the Music app may share the currently-playing track's details instead of an audio file, and Notes may offer its own collaboration link. If a share doesn't bring in what you expected, locate the file in the Finder and share it from there."),
            HelpSection(heading: "Files Textifyr can't read directly",
                body: "Pages, Numbers, Keynote, Word, Excel, and PowerPoint documents can't be read in their native format. When you try to share one, Textifyr tells you the best format to convert to first — usually Plain Text, Rich Text (RTF), PDF, or CSV — which you then share from the Finder. Textifyr does not read .docx or .xlsx directly, so export to one of the suggested formats rather than to Office formats."),
            HelpSection(heading: "Where shared content goes",
                body: "Text, web pages, PDFs, and OCR results are added directly as a source. Embedded images open in the Embed Image wizard, and audio/video open in the transcription wizard, so you can adjust settings before the content is finalised. If Textifyr was closed when you shared, the items are queued and added the next time you open the app."),
        ])
    ),
    HelpTopic(
        id: "troubleshooting",
        title: "Troubleshooting",
        icon: "wrench.and.screwdriver",
        content: HelpContent(sections: [
            HelpSection(heading: nil,
                body: "If something didn't work the way you expected, this section can help you figure out what's going on."),
            HelpSection(heading: "\"All text chunks were skipped by the content filter\"",
                body: "Your Mac's built-in AI has a safety checker that reads both your prompt and your text before it starts working. If the safety checker is not comfortable with what it sees, it blocks the result. When it blocks everything, you see this error.\n\nThink of it like a school librarian who quickly reads a book before putting it on the shelf. Most of the time the librarian is fine with it. But occasionally, even a perfectly normal book gets set aside because something on the page — a word, a topic, or just a combination of things — caught their attention that day.\n\nThe safety checker does not work from a fixed list of banned words. It makes more of a judgment call each time — which means the same text that was blocked once will often go through just fine the next time you try.\n\nCommon triggers:\n• Strong language, slurs, or offensive words — these often appear in casual real-world speech even when you did not intend them to be there\n• Sensitive topics such as violence, medical details, or adult content\n• Mixed alphabets in the same word or line — for example, a letter from the Russian or Greek alphabet sitting inside otherwise normal English text. This can happen when text is copied from a PDF, scanned from a photo, or captured by OCR, and a character gets recognised as the wrong letter. The safety checker has been trained to watch out for this because people sometimes use look-alike letters from other alphabets to sneak past word filters. Even one misidentified character — like a Cyrillic \"т\" where a plain Latin \"t\" belongs — can be enough to trigger the block. If you see this happening, open Smart Replace (the magnifying-glass button in the toolbar), paste the unusual character into the Find field, type the correct character in the Replace field, and tap Replace All before running your prompt again.\n• A combination of your prompt and your text that together tip the balance — even when each part on its own seems harmless\n• Text that looks like computer code or data — tables of numbers, coordinates, chemical formulas, or lots of symbols in a row can sometimes look suspicious to the checker, especially when mixed with the kinds of characters described above\n• Prompts that ask the AI to change, swap, or manipulate specific characters — instructions like \"change every comma to a tab\" or \"replace these letters\" can sound like an attempt to scramble a message, even when the intent is completely innocent. Instead of using the AI for this kind of job, use Smart Replace (the magnifying-glass button in the toolbar) — it is faster, more reliable, and will never trigger the content filter\n• Very long or very dense text — when a chunk is packed with technical terms, abbreviations, or unusual formatting, the checker has a harder time understanding what it is reading and may play it safe by blocking\n\nWhat to do:\n1. Try again. This is the most effective first step. Because the checker is not perfectly consistent, a second attempt succeeds more often than not.\n2. If it keeps failing, look at your source text for any of the triggers above — especially unusual characters from other alphabets that may have crept in through scanning or copying.\n3. Use Smart Replace (magnifying-glass button) to find and fix unusual characters before sending the text to the AI.\n4. Try simplifying your prompt — sometimes the wording of the instruction is what tips the balance, not the text itself.\n5. If the error only happens with one particular source, try splitting it into smaller pieces using the Splitter. A smaller chunk may not trigger the checker the same way."),
            HelpSection(heading: "Prompt not getting desired results",
                body: "Writing a good prompt is harder than it looks — and that is not your fault. Here is why, and what you can do about it.\n\nWhat is a prompt?\nA prompt is the instruction you give to the AI. It is like giving directions to someone who has never been to your house before. The clearer and more specific your directions, the more likely they are to arrive at the right place.\n\nWhy is it difficult?\nThe AI does not follow exact rules the way a calculator does. Instead, it reads your instruction and makes its best guess about what you mean. Small changes in wording — even changing \"summarise\" to \"describe\" — can produce very different results. The AI also does not know anything about your document unless you tell it. It only sees what is in the prompt and the text you provide.\n\nAnother challenge is that the AI tries to be helpful in ways you might not want. It may add an introduction you did not ask for, choose a different format than expected, or miss part of the task because the instruction was too general.\n\nThings to try when results are not right:\n\n1. Be specific about what you want in and what you want out. Instead of \"summarise this\", try \"write a three-sentence summary of the key points in this transcript\". The more you describe the shape of the answer you want, the better.\n\n2. Tell the AI what the text is. Starting your prompt with \"This is a meeting transcript\" or \"This is a list of scientific data\" helps the AI understand the context before it starts.\n\n3. Give an example. If you know what a good result looks like, describe it or show a small sample in the prompt. For example: \"Format each item like this: Name — Date — Amount.\"\n\n4. Break complex tasks into steps. If you want the AI to do several things — for example, clean up grammar, remove filler words, and then add a heading — it works better to have one action step for each task rather than listing everything in one long instruction.\n\n5. Avoid vague words like \"improve\" or \"make it better\". The AI does not know your standard for better. Use words that describe a specific change: \"remove filler words\", \"shorten each sentence to under 20 words\", \"add bullet points\".\n\n6. If the AI keeps adding phrases you do not want — like \"Sure, here is the result\" or \"Here is a summary of the text\" — add a line to your prompt such as: \"Return only the result. Do not add any introduction or sign-off.\"\n\n7. Test with a small piece of text first. Open the Prompt Builder (Tools → Prompt Builder, or ⌘⇧P) and paste just one paragraph. Test and adjust the prompt there before running it on your full document. This saves time and avoids repeated long processing runs.\n\n8. Use the AI Writer to troubleshoot your prompt. If you cannot figure out why a prompt is not working, paste it into the AI Writer source and ask: \"Why might this prompt not be giving good results, and how could I improve it?\" The AI can often spot problems in its own instructions that are hard to see from the outside."),
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
