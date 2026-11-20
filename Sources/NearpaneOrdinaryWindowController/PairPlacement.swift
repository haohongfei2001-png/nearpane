import AppKit
import CReadOnlySpaces
import NearpaneCore

/// An explicit request authorizes one final size per window. Keep each intermediate
/// move inside the envelope of the already visible source and destination.
enum PairPlacementGeometry {
    static func companion(_ plan: OrdinaryWindowPairPlacement, for id: ManagedWindowID,
                          destination: SurfaceRect) throws -> ManagedWindowID {
        let a = plan.leftFrame, b = plan.rightFrame
        guard plan.left.pid > 1, plan.right.pid > 1, plan.left.launch > 0, plan.right.launch > 0,
              plan.left.number > 0, plan.right.number > 0, plan.left.number != plan.right.number,
              plan.left.element != plan.right.element, a.geometry.isValid, b.geometry.isValid,
              a.x + a.width == b.x, a.y == b.y, a.height == b.height else { throw Refusal("左右两窗或相邻目标区域不完整。") }
        if id == plan.left && destination == a { return plan.right }
        if id == plan.right && destination == b { return plan.left }
        throw Refusal("窗口或最终目标与本次双窗拖放不符。")
    }

    static func steps(from: SurfaceRect, to: SurfaceRect) -> [SurfaceRect] {
        let atSource = SurfaceRect(x: from.x, y: from.y, width: to.width, height: to.height)
        let atTarget = SurfaceRect(x: to.x, y: to.y, width: from.width, height: from.height)
        let endX = max(from.x + from.width, to.x + to.width), endY = max(from.y + from.height, to.y + to.height)
        func fits(_ frame: SurfaceRect) -> Bool { frame.x + frame.width <= endX && frame.y + frame.height <= endY }
        let route: [SurfaceRect]
        if fits(atSource) { route = [atSource, to] }
        else if fits(atTarget) { route = [atTarget, to] }
        else {
            let x = min(from.x, to.x), y = min(from.y, to.y)
            route = [.init(x: x, y: y, width: from.width, height: from.height),
                     .init(x: x, y: y, width: to.width, height: to.height), to]
        }
        var previous = from
        return route.filter { next in
            defer { previous = next }
            return next != previous
        }
    }
}

enum OrdinaryGeometryReadback {
    case pending, confirmed, unexpected

    static func assess(from: SurfaceRect, to: SurfaceRect, ax: SurfaceRect, cg: SurfaceRect,
                       notifications: Int) -> Self {
        if ax != cg { return .pending }
        if cg != from && cg != to { return .unexpected }
        return cg == to && notifications == 1 ? .confirmed : .pending
    }
}

enum OrdinaryMinimumEvidence: Equatable {
    case published(CGSize), unpublished, unreadable

    static func classify(_ status: AXError, size: CGSize?, declared: [String]?) -> Self {
        if status == .success, let size, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
            return .published(size)
        }
        if status == .attributeUnsupported || (status == .noValue && declared?.contains("AXMinSize") == false) {
            return .unpublished
        }
        return .unreadable
    }

    static func read(_ element: AXUIElement) -> Self {
        var value: CFTypeRef?, rawNames: CFArray?, measured = CGSize.zero
        let status = AXUIElementCopyAttributeValue(element, "AXMinSize" as CFString, &value)
        let gotSize = value.map { CFGetTypeID($0) == AXValueGetTypeID() && AXValueGetValue($0 as! AXValue, .cgSize, &measured) } ?? false
        if status == .noValue, AXUIElementCopyAttributeNames(element, &rawNames) != .success { rawNames = nil }
        return classify(status, size: gotSize ? measured : nil, declared: rawNames as? [String])
    }

    func permits(_ destination: SurfaceRect, lastPublished: SurfaceRect?) -> Bool {
        switch self {
        case .published(let floor): return destination.width >= floor.width && destination.height >= floor.height
        case .unpublished:
            guard let lastPublished else { return true }
            return destination.width >= lastPublished.width && destination.height >= lastPublished.height
        case .unreadable: return false
        }
    }
}

/// Sizes are indivisible witnesses. Taking the narrow width of one and the short height
/// of another would invent an unobserved lower bound.
struct OrdinaryWitnessedSizes {
    var original: SurfaceRect?
    private(set) var latestPair: SurfaceRect?

    mutating func confirmed(_ actual: SurfaceRect) { latestPair = Self.size(actual) }

    func minimum(at current: SurfaceRect) -> SurfaceRect {
        if let original, Self.fits(current, original) { return Self.size(original) }
        if let latestPair, Self.fits(current, latestPair) { return latestPair }
        return Self.size(original ?? current)
    }

    func allowsOrdinary(_ target: SurfaceRect, currentFloor: SurfaceRect) -> Bool {
        if Self.fits(target, currentFloor) { return true }
        guard let latestPair else { return false }
        return Self.fits(target, latestPair) || original.map { Self.fits(target, $0) } == true
    }

    private static func size(_ f: SurfaceRect) -> SurfaceRect { .init(width: f.width, height: f.height) }
    private static func fits(_ f: SurfaceRect, _ floor: SurfaceRect) -> Bool {
        f.width >= floor.width && f.height >= floor.height
    }
}

/// The target monitor retains its original AX object. Pin the companion's current AX
/// object and kernel image for this write too, including across separate application workers.
struct PairPlacementFence {
    let plan: OrdinaryWindowPairPlacement
    let member: ManagedWindowID
    let peer: ManagedWindowID
    let peerElement: AXUIElement
    let images: [pid_t: OrdinaryProcessImage]

    init(_ plan: OrdinaryWindowPairPlacement, member: ManagedWindowID, destination: SurfaceRect,
         retainedPeer: AXUIElement?) throws {
        self.plan = plan
        self.member = member
        peer = try PairPlacementGeometry.companion(plan, for: member, destination: destination)
        try require(try displayID(plan.leftFrame) == plan.desktop.display && displayID(plan.rightFrame) == plan.desktop.display,
                    "双窗目标没有完整落在获准显示器。")
        var images = [pid_t: OrdinaryProcessImage]()
        for id in [member, peer] {
            let image = try OrdinaryProcessImage.read(id.pid)
            try require(image.launch == id.launch && (images[id.pid] == nil || images[id.pid] == image), "双窗进程代际已变化。")
            images[id.pid] = image
        }
        self.images = images
        let peerNumber = peer.number
        let peers = try windows(peer.pid).filter { number($0) == peerNumber }
        guard peers.count == 1, let selected = peers.first,
              retainedPeer.map({ CFEqual($0, selected) }) ?? true else { throw Refusal("同伴窗口的原 AX 身份不唯一。") }
        peerElement = selected
    }

    func check(memberFrame: SurfaceRect, memberElement: AXUIElement) throws {
        for (pid, image) in images { try require(try OrdinaryProcessImage.read(pid) == image, "双窗进程代际已变化。") }
        let peerWindows = try windows(peer.pid)
        let memberWindows = member.pid == peer.pid ? peerWindows : try windows(member.pid)
        let peers = peerWindows.filter { number($0) == peer.number }
        let members = memberWindows.filter { number($0) == member.number }
        try require(peers.count == 1 && CFEqual(peers[0], peerElement) &&
                    members.count == 1 && CFEqual(members[0], memberElement), "双窗已关闭、重建或不再唯一。")
        try require(try axRect(memberElement) == memberFrame, "本次目标窗口的实际 AX 几何已变化。")
        try ordinaryRole(memberElement)
        try ordinaryRole(peerElement)
        let peerAX = try axRect(peerElement)
        let ids = [member.number, peer.number]
        guard let rows = NPReadVisibleWindowDescriptions(ids, Int32(ids.count)) as? [[String: Any]], rows.count == 2 else {
            throw Refusal("WindowServer 无法确认两扇在屏窗口。")
        }
        for id in [member, peer] {
            let matches = rows.filter { $0[kCGWindowNumber as String] as? UInt32 == id.number }
            guard matches.count == 1, let row = matches.first, row[kCGWindowOwnerPID as String] as? pid_t == id.pid,
                  row[kCGWindowLayer as String] as? Int == 0, row[kCGWindowIsOnscreen as String] as? Bool == true,
                  let raw = row[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: raw)
            else { throw Refusal("WindowServer 的双窗进程、层或几何已变化。") }
            let frame = SurfaceRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            try require(try displayID(frame) == plan.desktop.display && frame == (id == peer ? peerAX : memberFrame), "同伴 AX/CG 几何或双窗显示器已变化。")
        }
        try checkCurrentSpace()
        for (pid, image) in images { try require(try OrdinaryProcessImage.read(pid) == image, "读回途中双窗进程代际已变化。") }
    }

    func checkCurrentSpace() throws {
        try require(OrdinaryDesktopMembership.containsPair(member.number, peer.number, on: plan.desktop),
                    "双窗未能双向确认唯一属于本屏当前的获准普通桌面。")
    }
}
