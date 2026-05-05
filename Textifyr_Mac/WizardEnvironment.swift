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
