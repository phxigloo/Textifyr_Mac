import SwiftUI
import TextifyrModels

struct StageBadgeView: View {
    let stage: WorkStage

    var body: some View {
        Text(stage.name)
            .font(.caption2).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stage.color)
            .foregroundStyle(stage.textColor)
            .clipShape(Capsule())
    }
}
