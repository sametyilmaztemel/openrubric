#if os(macOS)
import AppKit
import CoreGraphics
import ScreenCaptureKit
import OpenRubricCore

/// Captures the cursor-centered crop via ScreenCaptureKit.
///
/// Flow: `SCShareableContent` -> pick the display whose frame contains
/// the cursor -> `SCScreenshotManager.captureImage` at the display's
/// native pixel resolution -> `CropGeometry.cropped` -> PNG data ready
/// for the vision call.
///
/// Coordinate spaces: `SCShareableDisplay.frame` is in screen POINTS
/// with a top-left origin (y grows downward) — the same space the
/// global top-left cursor point arrives in. The captured image is in
/// PIXELS; `CropGeometry.cropped` maps points->pixels per display.
final class ScreenCaptureService: @unchecked Sendable {

    /// Captures `2 * radius` points around `cursor` (global top-left
    /// screen coordinates) and returns the crop as PNG data.
    func captureCrop(cursor: CGPoint, radius: CGFloat) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = display(containing: cursor, in: content.displays) else {
            throw CaptureError.noDisplayForCursor
        }

        let displayRect = DisplayRect(
            origin: CGPoint(x: display.frame.minX, y: display.frame.minY),
            size: CGSize(width: display.frame.width, height: display.frame.height)
        )
        guard let crop = CropGeometry.crop(cursor: cursor, radius: radius, display: displayRect) else {
            throw CaptureError.cropTooSmall
        }

        let configuration = SCStreamConfiguration()
        // Whole display at native pixel size (Apple's SCK sample uses
        // width/height * pixelScale); the crop-to-pixel mapping happens
        // in CropGeometry.cropped.
        let scale = display.pixelScale
        configuration.width = Int(display.frame.width * scale)
        configuration.height = Int(display.frame.height * scale)
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        guard let cropped = CropGeometry.cropped(image, crop: crop) else {
            throw CaptureError.croppedImageNil
        }
        guard let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else {
            throw CaptureError.pngEncodingFailed
        }
        return png
    }

    /// The display whose frame contains the cursor. Falls back to the
    /// main display (frame origin .zero in screen coordinates), then to
    /// the largest display, so an off-screen cursor never kills capture.
    private func display(containing cursor: CGPoint, in displays: [SCShareableDisplay]) -> SCShareableDisplay? {
        guard !displays.isEmpty else { return nil }
        for display in displays where display.frame.contains(cursor) {
            return display
        }
        for display in displays where display.frame.origin == .zero {
            return display
        }
        return displays.max { a, b in
            a.frame.width * a.frame.height < b.frame.width * b.frame.height
        }
    }

    enum CaptureError: LocalizedError {
        case noDisplayForCursor
        case cropTooSmall
        case croppedImageNil
        case pngEncodingFailed

        var errorDescription: String? {
            switch self {
            case .noDisplayForCursor:
                return "No display found for the cursor position."
            case .cropTooSmall:
                return "The cursor-centered crop is too small to capture."
            case .croppedImageNil:
                return "Crop produced an empty image."
            case .pngEncodingFailed:
                return "Failed to encode the crop as PNG."
            }
        }
    }
}

#endif
