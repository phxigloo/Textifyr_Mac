import Foundation
import AppKit
import ScreenCaptureKit

enum ScreenCaptureService {

    /// Captures all connected displays, excluding the current app's windows.
    /// Returns an ordered list of (display name, CGImage) for each display.
    static func captureAllDisplays() async throws -> [(name: String, image: CGImage)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw TextifyrCaptureError.noDisplayFound
        }

        let excludedApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        var results: [(name: String, image: CGImage)] = []
        for (index, display) in content.displays.enumerated() {
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            let name = "Display \(index + 1) (\(display.width)×\(display.height))"
            results.append((name: name, image: image))
        }
        return results
    }
}

enum TextifyrCaptureError: LocalizedError {
    case noDisplayFound
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .noDisplayFound: return "No display found for screen capture."
        case .saveFailed:     return "Failed to save captured image."
        }
    }
}
