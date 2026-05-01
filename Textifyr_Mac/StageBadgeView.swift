import SwiftUI
import TextifyrModels

struct StageBadgeView: View {
    let stage: WorkStage

    var body: some View {
        Text(stage.name)
            .font(.caption2).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(stage.textColor)
            .background { Capsule().fill(stage.color) }
    }
}

#Preview("Draft stage") {
    let _ = makePreviewContainer()
    let stage = previewStage()
    return StageBadgeView(stage: stage)
        .padding()
}
