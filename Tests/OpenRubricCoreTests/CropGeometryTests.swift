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
}
#endif
