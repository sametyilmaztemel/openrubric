#if !canImport(CoreGraphics)
// Minimal CoreGraphics geometry types for non-Darwin platforms (Linux CI,
// local test runs). They mirror the Darwin definitions for everything
// CropGeometry uses. On macOS the real CoreGraphics types are used and
// this file compiles to nothing.
public typealias CGFloat = Double

public struct CGPoint: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public static let zero = CGPoint(x: 0, y: 0)
}

public struct CGSize: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    public static let zero = CGSize(width: 0, height: 0)
}

public struct CGRect: Equatable, Sendable {
    public var origin: CGPoint
    public var size: CGSize

    public init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.origin = CGPoint(x: x, y: y)
        self.size = CGSize(width: width, height: height)
    }

    public var minX: CGFloat { origin.x }
    public var minY: CGFloat { origin.y }
    public var midX: CGFloat { origin.x + size.width / 2 }
    public var midY: CGFloat { origin.y + size.height / 2 }
    public var maxX: CGFloat { origin.x + size.width }
    public var maxY: CGFloat { origin.y + size.height }
    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }

    public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }

    public static func intersection(_ a: CGRect, _ b: CGRect) -> CGRect {
        let x1 = max(a.minX, b.minX)
        let y1 = max(a.minY, b.minY)
        let x2 = min(a.maxX, b.maxX)
        let y2 = min(a.maxY, b.maxY)
        return CGRect(x: x1, y: y1, width: max(0, x2 - x1), height: max(0, y2 - y1))
    }
}
#endif
