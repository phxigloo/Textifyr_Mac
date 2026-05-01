// Shared helpers for #Preview macros across all Mac views.
// Never compiled into production builds — Xcode only uses it for the canvas.

import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

// MARK: - Container

/// Creates a fresh in-memory ModelContainer pre-seeded with representative dummy data.
@MainActor
func makePreviewContainer() -> ModelContainer {
    let schema = Schema([
        TextifyrDocument.self,
        SourceSession.self,
        ConversationMessage.self,
        FormattingPipeline.self,
        PipelineStep.self,
        WorkStage.self,
    ])
    let c = try! ModelContainer(
        for: schema,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    seedPreviewData(in: c.mainContext)
    return c
}

@MainActor
func seedPreviewData(in ctx: ModelContext) {
    // Stages
    let stages = [
        WorkStage(name: "Draft",       colorHex: "#808080", textColorHex: "#FFFFFF", sortOrder: 0),
        WorkStage(name: "Transcribed", colorHex: "#2196F3", textColorHex: "#FFFFFF", sortOrder: 1),
        WorkStage(name: "Formatted",   colorHex: "#9C27B0", textColorHex: "#FFFFFF", sortOrder: 2),
        WorkStage(name: "Reviewed",    colorHex: "#FF9800", textColorHex: "#FFFFFF", sortOrder: 3),
    ]
    stages.forEach { ctx.insert($0) }

    // Output pipeline (with two steps)
    let outPipeline = FormattingPipeline(name: "Meeting Minutes", mode: .serial)
    outPipeline.scopeRawValue = "output"
    ctx.insert(outPipeline)
    let outStep1 = PipelineStep(name: "Format",     prompt: "Format this transcript as meeting minutes with action items.", sortOrder: 0)
    let outStep2 = PipelineStep(name: "Summarise",  prompt: "Add a one-paragraph executive summary at the top.",           sortOrder: 1)
    [outStep1, outStep2].forEach {
        ctx.insert($0)
        $0.pipeline = outPipeline
    }
    outPipeline.steps = [outStep1, outStep2]

    // Source pipeline
    let srcPipeline = FormattingPipeline(name: "Key Points", mode: .serial)
    srcPipeline.scopeRawValue = "source"
    ctx.insert(srcPipeline)
    let srcStep = PipelineStep(name: "Summarise", prompt: "List the 5 most important points from this transcript.", sortOrder: 0)
    ctx.insert(srcStep)
    srcStep.pipeline = srcPipeline
    srcPipeline.steps = [srcStep]

    // Document 1 – with a source session
    let doc1 = TextifyrDocument(title: "Q1 Planning Meeting")
    doc1.stage     = stages[0]
    doc1.pipeline  = outPipeline
    doc1.sortOrder = 0
    ctx.insert(doc1)

    let session1 = SourceSession()
    session1.rawText   = "John: We need to review the Q1 budget.\nSarah: Let's allocate more to marketing.\nJohn: Good — I'll prepare the slides by Friday."
    session1.sortOrder = 0
    ctx.insert(session1)
    doc1.sourceSessions = [session1]

    // Document 2 – empty
    let doc2 = TextifyrDocument(title: "Product Roadmap Review")
    doc2.stage     = stages[1]
    doc2.sortOrder = 1
    ctx.insert(doc2)

    try? ctx.save()
}

// MARK: - Convenience accessors

@MainActor
func previewDocument(in c: ModelContainer) -> TextifyrDocument {
    (try? c.mainContext.fetch(FetchDescriptor<TextifyrDocument>(sortBy: [SortDescriptor(\.sortOrder)])))?.first
        ?? TextifyrDocument(title: "Preview Doc")
}

@MainActor
func previewSession(in c: ModelContainer) -> SourceSession {
    (try? c.mainContext.fetch(FetchDescriptor<SourceSession>()))?.first ?? SourceSession()
}

@MainActor
func previewOutputPipeline(in c: ModelContainer) -> FormattingPipeline {
    let desc = FetchDescriptor<FormattingPipeline>()
    let all  = (try? c.mainContext.fetch(desc)) ?? []
    return all.first { $0.scopeRawValue == "output" } ?? FormattingPipeline(name: "Preview Pipeline")
}

@MainActor
func previewStage() -> WorkStage {
    WorkStage(name: "Draft", colorHex: "#2196F3", textColorHex: "#FFFFFF", sortOrder: 0)
}

@MainActor
func previewAppState(selectedIn c: ModelContainer) -> AppState {
    let state = AppState()
    state.selectedDocument = previewDocument(in: c)
    return state
}

// MARK: - ViewModel factories

@MainActor
func previewDocumentVM(in c: ModelContainer) -> DocumentEditorViewModel {
    DocumentEditorViewModel(document: previewDocument(in: c), context: c.mainContext)
}

@MainActor
func previewChatVM(in c: ModelContainer) -> SessionChatViewModel {
    SessionChatViewModel(session: previewSession(in: c), context: c.mainContext)
}

@MainActor
func previewPipelineVM(in c: ModelContainer) -> PipelineEditorViewModel {
    PipelineEditorViewModel(pipeline: previewOutputPipeline(in: c), context: c.mainContext)
}

@MainActor
func previewCaptureVM(in c: ModelContainer) -> InputCaptureViewModel {
    InputCaptureViewModel(document: previewDocument(in: c), context: c.mainContext, appState: AppState())
}
