import Foundation

public enum GeometryError: Error, Equatable {
    case invalidGeometry, incompatibleLogicalUnits, unsupportedTopology, outsidePreview
}

public struct Point: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public var isFinite: Bool { x.isFinite && y.isFinite }
}

/// Rectangles are continuous extents. Hit testing uses [min, max) on both axes.
public struct Rect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { width * height }
    public var isValid: Bool {
        [x, y, width, height, maxX, maxY, area].allSatisfy(\.isFinite)
            && width > 0 && height > 0 && maxX > x && maxY > y && area > 0
    }
    public var corners: [Point] {
        [Point(x, y), Point(maxX, y), Point(x, maxY), Point(maxX, maxY)]
    }
    public func contains(_ point: Point) -> Bool {
        isValid && point.isFinite && point.x >= x && point.x < maxX
            && point.y >= y && point.y < maxY
    }
    public func intersection(_ other: Rect) -> Rect? {
        guard isValid, other.isValid else { return nil }
        let result = Rect(max(x, other.x), max(y, other.y),
                          min(maxX, other.maxX) - max(x, other.x),
                          min(maxY, other.maxY) - max(y, other.y))
        return result.isValid ? result : nil
    }
    public func componentError(from other: Rect) -> Double {
        max(abs(x - other.x), abs(y - other.y),
            abs(width - other.width), abs(height - other.height))
    }
    public func mapped(_ transform: (Point) throws -> Point) throws -> Rect {
        guard isValid else { throw GeometryError.invalidGeometry }
        let points = try corners.map(transform)
        guard points.allSatisfy(\.isFinite) else { throw GeometryError.invalidGeometry }
        let xs = points.map(\.x), ys = points.map(\.y)
        let result = Rect(xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        guard result.isValid else { throw GeometryError.invalidGeometry }
        return result
    }
    /// Conservative rectangular occlusion, including windows that cannot be targeted.
    public func subtracting(_ cover: Rect) -> [Rect] {
        guard isValid else { return [] }
        guard let cut = intersection(cover) else { return [self] }
        return [Rect(x, y, width, cut.y - y),
                Rect(x, cut.maxY, width, maxY - cut.maxY),
                Rect(x, cut.y, cut.x - x, cut.height),
                Rect(cut.maxX, cut.y, maxX - cut.maxX, cut.height)].filter(\.isValid)
    }
}

/// Clockwise rotation from an unrotated, top-left-origin synthetic backing raster.
/// This is NOT an assertion about a display's native physical pixel resolution.
public enum QuarterTurn: Int, CaseIterable, Sendable {
    case zero = 0, clockwise90 = 90, half = 180, clockwise270 = 270
}

public struct DisplayCoordinateTransform: Sendable {
    public let displayID: String
    public let appKitFrame: Rect
    public let cgBounds: Rect
    public let backingScale: Double
    public let rotation: QuarterTurn

    public init(displayID: String, appKitFrame: Rect, cgBounds: Rect,
                backingScale: Double, rotation: QuarterTurn) throws {
        guard !displayID.isEmpty, appKitFrame.isValid, cgBounds.isValid,
              backingScale.isFinite, backingScale > 0,
              Rect(0, 0, cgBounds.width * backingScale, cgBounds.height * backingScale).isValid else {
            throw GeometryError.invalidGeometry
        }
        // The experiment accepts logical point bounds only, never silently rescales them.
        guard abs(appKitFrame.width - cgBounds.width) <= 1e-6,
              abs(appKitFrame.height - cgBounds.height) <= 1e-6 else {
            throw GeometryError.incompatibleLogicalUnits
        }
        self.displayID = displayID; self.appKitFrame = appKitFrame; self.cgBounds = cgBounds
        self.backingScale = backingScale; self.rotation = rotation
    }

    private func checked(_ point: Point) throws -> Point {
        guard point.isFinite else { throw GeometryError.invalidGeometry }
        return point
    }
    public func appKitToCG(_ p: Point) throws -> Point {
        _ = try checked(p)
        return try checked(Point(cgBounds.x + p.x - appKitFrame.x,
                                 cgBounds.y + appKitFrame.maxY - p.y))
    }
    public func cgToAppKit(_ p: Point) throws -> Point {
        _ = try checked(p)
        return try checked(Point(appKitFrame.x + p.x - cgBounds.x,
                                 appKitFrame.maxY - (p.y - cgBounds.y)))
    }
    public func appKitToCG(_ rect: Rect) throws -> Rect { try rect.mapped(appKitToCG) }
    public func cgToAppKit(_ rect: Rect) throws -> Rect { try rect.mapped(cgToAppKit) }

    public func cgToOrientedBacking(_ p: Point) throws -> Point {
        _ = try checked(p)
        return try checked(Point((p.x - cgBounds.x) * backingScale,
                                 (p.y - cgBounds.y) * backingScale))
    }
    public func orientedBackingToCG(_ p: Point) throws -> Point {
        _ = try checked(p)
        return try checked(Point(p.x / backingScale + cgBounds.x, p.y / backingScale + cgBounds.y))
    }
    public func cgToUnrotatedBacking(_ p: Point) throws -> Point {
        _ = try checked(p)
        let x = p.x - cgBounds.x, y = p.y - cgBounds.y
        let w = cgBounds.width, h = cgBounds.height
        let local: Point
        switch rotation {
        case .zero: local = Point(x, y)
        case .clockwise90: local = Point(y, w - x)
        case .half: local = Point(w - x, h - y)
        case .clockwise270: local = Point(h - y, x)
        }
        return try checked(Point(local.x * backingScale, local.y * backingScale))
    }
    public func unrotatedBackingToCG(_ p: Point) throws -> Point {
        _ = try checked(p)
        let u = p.x / backingScale, v = p.y / backingScale
        let local: Point
        switch rotation {
        case .zero: local = Point(u, v)
        case .clockwise90: local = Point(cgBounds.width - v, u)
        case .half: local = Point(cgBounds.width - u, cgBounds.height - v)
        case .clockwise270: local = Point(v, cgBounds.height - u)
        }
        return try checked(Point(local.x + cgBounds.x, local.y + cgBounds.y))
    }
    public func cgToOrientedBacking(_ r: Rect) throws -> Rect { try r.mapped(cgToOrientedBacking) }
    public func orientedBackingToCG(_ r: Rect) throws -> Rect { try r.mapped(orientedBackingToCG) }
    public func cgToUnrotatedBacking(_ r: Rect) throws -> Rect { try r.mapped(cgToUnrotatedBacking) }
    public func unrotatedBackingToCG(_ r: Rect) throws -> Rect { try r.mapped(unrotatedBackingToCG) }
}

public struct DisplaySlice: Sendable {
    public let displayID: String
    public let cgRect: Rect
    public let appKitRect: Rect
    public let orientedBackingRect: Rect
    public let unrotatedBackingRect: Rect
    public let fractionOfWindow: Double
}

public struct DesktopGeometry: Sendable {
    public let displays: [DisplayCoordinateTransform]
    public let primary: DisplayCoordinateTransform
    public init(displays: [DisplayCoordinateTransform], primaryID: String) throws {
        guard !displays.isEmpty, Set(displays.map(\.displayID)).count == displays.count,
              let primary = displays.first(where: { $0.displayID == primaryID }) else {
            throw GeometryError.unsupportedTopology
        }
        for (index, display) in displays.enumerated() {
            // Verify a single global origin, not independent per-monitor fits.
            guard try primary.appKitToCG(display.appKitFrame).componentError(from: display.cgBounds) <= 1e-6,
                  !displays.prefix(index).contains(where: { $0.cgBounds.intersection(display.cgBounds) != nil }) else {
                throw GeometryError.unsupportedTopology
            }
        }
        self.displays = displays; self.primary = primary
    }
    public func appKitToCG(_ r: Rect) throws -> Rect { try primary.appKitToCG(r) }
    public func cgToAppKit(_ r: Rect) throws -> Rect { try primary.cgToAppKit(r) }
    public func slices(of rect: Rect) throws -> [DisplaySlice] {
        guard rect.isValid else { throw GeometryError.invalidGeometry }
        return try displays.compactMap { display in
            guard let clip = rect.intersection(display.cgBounds) else { return nil }
            return try DisplaySlice(displayID: display.displayID, cgRect: clip,
                                    appKitRect: display.cgToAppKit(clip),
                                    orientedBackingRect: display.cgToOrientedBacking(clip),
                                    unrotatedBackingRect: display.cgToUnrotatedBacking(clip),
                                    fractionOfWindow: clip.area / rect.area)
        }
    }
    public func uncoveredArea(of rect: Rect) throws -> Double {
        max(0, rect.area - (try slices(of: rect)).reduce(0) { $0 + $1.cgRect.area })
    }
}

/// One transform for the whole display/Space viewport; never fit individual windows.
public struct PreviewTransform: Sendable {
    public let source: Rect
    public let content: Rect
    public let scale: Double
    public init(source: Rect, viewport: Rect) throws {
        guard source.isValid, viewport.isValid else { throw GeometryError.invalidGeometry }
        let scale = min(viewport.width / source.width, viewport.height / source.height)
        let w = source.width * scale, h = source.height * scale
        let content = Rect(viewport.x + (viewport.width - w) / 2,
                           viewport.y + (viewport.height - h) / 2, w, h)
        guard scale.isFinite, scale > 0, content.isValid else { throw GeometryError.invalidGeometry }
        self.source = source; self.scale = scale; self.content = content
    }
    public func project(_ p: Point) throws -> Point {
        let result = Point(content.x + (p.x - source.x) * scale, content.y + (p.y - source.y) * scale)
        guard p.isFinite, result.isFinite else { throw GeometryError.invalidGeometry }
        return result
    }
    public func project(_ r: Rect) throws -> Rect { try r.mapped(project) }
    public func unproject(_ p: Point) throws -> Point {
        guard content.contains(p) else { throw GeometryError.outsidePreview }
        let result = Point(source.x + (p.x - content.x) / scale, source.y + (p.y - content.y) / scale)
        guard result.isFinite else { throw GeometryError.invalidGeometry }
        return result
    }
}

public struct HitRegion: Sendable {
    public let key: String
    public let bounds: Rect
    public let frontToBackIndex: Int
    public let identityEligible: Bool
    public init(key: String, bounds: Rect, frontToBackIndex: Int, identityEligible: Bool) {
        self.key = key; self.bounds = bounds; self.frontToBackIndex = frontToBackIndex
        self.identityEligible = identityEligible
    }
}
public enum HitResult: Equatable, Sendable {
    case none, candidate(String), blocked(String), ambiguous([String])
}
public enum HitTesting {
    public static func hit(_ point: Point, regions: [HitRegion]) throws -> HitResult {
        guard point.isFinite, regions.allSatisfy({ $0.bounds.isValid && $0.frontToBackIndex >= 0 }),
              Set(regions.map(\.key)).count == regions.count else { throw GeometryError.invalidGeometry }
        let hits = regions.filter { $0.bounds.contains(point) }
        guard let firstIndex = hits.map(\.frontToBackIndex).min() else { return .none }
        let front = hits.filter { $0.frontToBackIndex == firstIndex }
        guard front.count == 1 else { return .ambiguous(front.map(\.key).sorted()) }
        return front[0].identityEligible ? .candidate(front[0].key) : .blocked(front[0].key)
    }
    public static func visibleFragments(of rect: Rect, occluders: [Rect]) throws -> [Rect] {
        guard rect.isValid, occluders.allSatisfy(\.isValid) else { throw GeometryError.invalidGeometry }
        return occluders.reduce([rect]) { pieces, cover in pieces.flatMap { $0.subtracting(cover) } }
    }
}
