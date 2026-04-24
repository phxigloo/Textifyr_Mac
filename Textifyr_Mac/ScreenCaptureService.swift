import Foundation
import AppKit
import ScreenCaptureKit

enum ScreenCaptureService {
    /// Captures the main screen and writes a PNG to a temp file, returning its URL.
    static func captureScreen() async throws -> URL {
        // Request permission first (SCShareableContent implicitly triggers it)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw TextifyrCaptureError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width  = display.width
        config.height = display.height

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw TextifyrCaptureError.saveFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw TextifyrCaptureError.saveFailed
        }
        return url
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
