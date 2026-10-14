#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A rectangle in display coordinates (top-left origin, points).
public struct DisplayRect: Equatable, Sendable {
    public let origin: CGPoint
    public let size: CGSize

    public init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }

    public var minX: CGFloat { origin.x }
    public var minY: CGFloat { origin.y }
    public var maxX: CGFloat { origin.x + size.width }
    public var maxY: CGFloat { origin.y + size.height }
    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }
}

/// Computes the crop region for a cursor-centered capture.
///
/// The crop is a square of side `2 * radius` around the cursor, clamped
/// to the display bounds. Cursor positions outside the display are
/// clamped so the crop always intersects the screen.
public enum CropGeometry {

    public struct Crop: Equatable, Sendable {
        public let displayRect: DisplayRect
        public let cropRect: CGRect

        public init(displayRect: DisplayRect, cropRect: CGRect) {
            self.displayRect = displayRect
            self.cropRect = cropRect
        }
    }

    /// Returns the clamped crop, or `nil` when the crop is smaller than
    /// `minimumSize` on either axis (e.g. cursor far outside a tiny display).
    public static func crop(
        cursor: CGPoint,
        radius: CGFloat,
        display: DisplayRect,
        minimumSize: CGFloat = 80
    ) -> Crop? {
        guard radius > 0 else { return nil }
        let side = radius * 2
        var x = cursor.x - radius
        var y = cursor.y - radius

        // Clamp so the crop stays inside the display when possible;
        // otherwise slide it so at least a `minimumSize` slice overlaps.
        if display.width >= side {
            x = max(display.minX, min(x, display.maxX - side))
        } else {
            x = (display.minX + display.maxX - side) / 2
        }
        if display.height >= side {
            y = max(display.minY, min(y, display.maxY - side))
        } else {
            y = (display.minY + display.maxY - side) / 2
        }

        let rect = CGRect(x: x, y: y, width: side, height: side)
        let overlap = CGRect.intersection(rect, CGRect(origin: display.origin, size: display.size))
        guard overlap.width >= minimumSize, overlap.height >= minimumSize else {
            return nil
        }
        return Crop(displayRect: display, cropRect: rect)
    }

#if canImport(CoreGraphics)
    /// Crops an image (top-left origin, pixels) to the crop rect.
    /// Assumes `image` covers the whole display (one SCK display capture).
    public static func cropped(
        _ image: CGImage,
        crop: Crop
    ) -> CGImage? {
        let scale = crop.displayRect.width > 0
            ? CGFloat(image.width) / crop.displayRect.width
            : 1
        // Round the two edges independently and derive the size from them,
        // so fractional scales cannot shift or shrink the crop by a pixel.
        let x0 = (crop.cropRect.minX * scale).rounded()
        let y0 = (crop.cropRect.minY * scale).rounded()
        let x1 = (crop.cropRect.maxX * scale).rounded()
        let y1 = (crop.cropRect.maxY * scale).rounded()
        let region = CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !region.isEmpty else { return nil }
        return image.cropping(to: region)
    }
#endif
}
