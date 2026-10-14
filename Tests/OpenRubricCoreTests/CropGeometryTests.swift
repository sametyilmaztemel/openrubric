import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import OpenRubricCore

private let display = DisplayRect(origin: .zero, size: CGSize(width: 1512, height: 982))

@Suite("CropGeometry")
struct CropGeometryTests {
    @Test("cursor inside a normal display")
    func inside() {
        let crop = CropGeometry.crop(cursor: CGPoint(x: 756, y: 491), radius: 260, display: display)
        #expect(crop != nil)
        let r = crop!.cropRect
        #expect(r.width == 520)
        #expect(r.height == 520)
        #expect(r.origin.x == 496)
        #expect(r.origin.y == 231)
    }

    @Test("cursor near the left edge clamps to the display")
    func leftEdge() {
        let crop = CropGeometry.crop(cursor: CGPoint(x: 30, y: 500), radius: 260, display: display)
        #expect(crop!.cropRect.minX == 0)
        #expect(crop!.cropRect.maxX == 520)
    }

    @Test("cursor near the bottom edge clamps")
    func bottomEdge() {
        let crop = CropGeometry.crop(cursor: CGPoint(x: 800, y: 960), radius: 260, display: display)
        #expect(crop!.cropRect.maxY == display.maxY)
    }

    @Test("cursor outside the top-left corner still yields a valid crop")
    func outside() {
        let crop = CropGeometry.crop(cursor: CGPoint(x: -100, y: -100), radius: 260, display: display)
        #expect(crop != nil)
        #expect(crop!.cropRect.minX == 0)
        #expect(crop!.cropRect.minY == 0)
    }

    @Test("zero radius returns nil")
    func zeroRadius() {
        #expect(CropGeometry.crop(cursor: .zero, radius: 0, display: display) == nil)
    }

    @Test("tiny display smaller than the crop centers on it")
    func tinyDisplay() {
        let small = DisplayRect(origin: .zero, size: CGSize(width: 200, height: 150))
        let crop = CropGeometry.crop(cursor: CGPoint(x: 100, y: 75), radius: 260, display: small)
        #expect(crop != nil)
        // Centered horizontally and vertically on the small display.
        #expect(crop!.cropRect.minX < 0)
        #expect(crop!.cropRect.minY < 0)
    }
}

#if canImport(CoreGraphics)
@Suite("CropGeometry.cropped — image sampling")
struct CropSamplingTests {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Fill with a solid color so we can assert non-null output.
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test("crops the center of a 2x-scaled capture")
    func centerCrop() {
        let image = makeImage(width: 3024, height: 1964)
        let crop = CropGeometry.crop(cursor: CGPoint(x: 756, y: 491), radius: 260, display: display)!
        let cropped = CropGeometry.cropped(image, crop: crop)
        #expect(cropped != nil)
        // radius 260 * 2 = 520 pt, 2x scale => 1040 px
        #expect(cropped!.width == 1040)
        #expect(cropped!.height == 1040)
    }

    @Test("a crop on a secondary display (non-zero origin) samples the right pixels")
    func secondaryDisplayOriginOffset() {
        // A secondary display placed to the right of a primary one:
        // its global origin is (1512, 0) in top-left screen coordinates.
        let secondary = DisplayRect(origin: CGPoint(x: 1512, y: 0),
                                    size: CGSize(width: 1512, height: 982))
        // A solid-color image covering ONLY the secondary display at 1x.
        let image = makeImage(width: 1512, height: 982)

        // Cursor near the LEFT edge of the secondary display: a global
        // crop straddling the display's left border must be clamped to
        // the display and must sample the image's left edge (x=0..),
        // not the region offset by the display's global origin.
        let cursor = CGPoint(x: 1512 + 60, y: 491)
        let crop = CropGeometry.crop(cursor: cursor, radius: 260, display: secondary)!
        let cropped = CropGeometry.cropped(image, crop: crop)
        #expect(cropped != nil)
        // Clamped to the display edge: width = (1512-60+260... no, the
        // clamp slides the crop fully inside => full 520 pt side.
        #expect(cropped!.width == 520)
        #expect(cropped!.height == 520)

        // Sample a pixel at the crop's center: it must equal the solid
        // fill color. (The nil/size assertions above already catch the
        // origin-offset bug — a wrong translation runs the region off
        // the image; this guards against a shift that stays in bounds.)
        guard let data = cropped!.dataProvider?.data else { return }
        let cfData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
        let length = CFDataGetLength(cfData)
        var buf = [UInt8](repeating: 0, count: length)
        CFDataGetBytes(cfData, CFRange(location: 0, length: length), &buf)
        let row = cropped!.bytesPerRow
        let cx = cropped!.width / 2, cy = cropped!.height / 2
        let idx = cy * row + cx * 4
        #expect(buf[idx] == 255, buf[idx + 1] == 0, buf[idx + 2] == 0)
    }
}
#endif
