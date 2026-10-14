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

    public func intersection(_ other: CGRect) -> CGRect {
        let x1 = max(minX, other.minX)
        let y1 = max(minY, other.minY)
        let x2 = min(maxX, other.maxX)
        let y2 = min(maxY, other.maxY)
        return CGRect(x: x1, y: y1, width: max(0, x2 - x1), height: max(0, y2 - y1))
    }
}
#endif

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
extension URLComponents {
    /// `path` is a non-optional `String` on both Darwin Foundation and
    /// swift-corelibs-foundation; kept as a single accessor so the URL
    /// plumbing in the clients stays platform-agnostic.
    var pathString: String { path }
}
