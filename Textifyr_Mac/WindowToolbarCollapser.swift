import SwiftUI
import AppKit

/// Collapses the window toolbar bar so it takes zero vertical space.
///
/// SwiftUI's `.toolbar(.hidden, for: .windowToolbar)` only hides items — it
/// never sets `NSToolbar.isVisible`, so the bar height (~44pt) remains.
/// This view calls the AppKit property directly, which actually collapses the
/// space. Running in `updateNSView` ensures it re-applies after every SwiftUI
/// layout pass so the framework cannot reset it.
private struct ToolbarSpaceCollapser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.toolbar?.isVisible = false
        }
    }
}

extension View {
    /// Collapses the containing NSWindow's toolbar bar to zero height.
    func collapseWindowToolbar() -> some View {
        background(ToolbarSpaceCollapser())
    }
}
