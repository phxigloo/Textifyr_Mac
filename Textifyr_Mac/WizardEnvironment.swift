import SwiftUI

/// Injected by the inline wizard container so every wizard view can dismiss
/// without relying on `@Environment(\.dismiss)` (which only works in sheets).
/// Falls back gracefully: if nil, wizards call their standard `dismiss()`.
private struct WizardDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var wizardDismiss: (() -> Void)? {
        get { self[WizardDismissKey.self] }
        set { self[WizardDismissKey.self] = newValue }
    }
}

/// Whether a step's prompt editor may offer the "Prompt Builder" / "Improve Prompt" buttons,
/// which navigate the *main window* to `.promptBuilder` mode. False when the action editor is
/// hosted in a sheet over a wizard — that jump would unmount the wizard behind the sheet. The
/// self-contained inline improve panel (Spec 2) replaces those buttons in that context.
private struct PromptBuilderAvailableKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var promptBuilderAvailable: Bool {
        get { self[PromptBuilderAvailableKey.self] }
        set { self[PromptBuilderAvailableKey.self] = newValue }
    }
}

/// True when an outer container (the scoped action-editor sheet) owns commit/rollback via its own
/// Done/Cancel. A step-detail view then hides its per-action Save/Discard controls and dirty dot,
/// which would be redundant and confusing alongside the sheet's footer buttons.
private struct PipelineCommitsExternallyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var pipelineCommitsExternally: Bool {
        get { self[PipelineCommitsExternallyKey.self] }
        set { self[PipelineCommitsExternallyKey.self] = newValue }
    }
}

/// Provided by the scoped action-editor sheet (Spec 2): opens its self-contained inline improve
/// panel for the given step index. When present, a step row shows an "Improve" button that calls
/// this instead of navigating the main window to the Prompt Builder. Nil in the main-window editor.
private struct InlineImproveKey: EnvironmentKey {
    static let defaultValue: ((Int) -> Void)? = nil
}

extension EnvironmentValues {
    var inlineImprove: ((Int) -> Void)? {
        get { self[InlineImproveKey.self] }
        set { self[InlineImproveKey.self] = newValue }
    }
}
