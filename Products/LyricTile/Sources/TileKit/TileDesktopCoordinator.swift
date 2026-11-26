import AppKit
import Darwin
import Foundation

/// Native observation and presentation adapter for independent tiles. The host can
/// reuse TileGeometry directly and does not need separate floating component windows.
@MainActor
public final class TileDesktopCoordinator {
    private let store: RegistryWorker
    private var member: TileMember
    private let windowIDs: @MainActor () -> [UInt32]
    private let permit: @MainActor (Bool) -> Void
    private let place: @MainActor (NSRect, String) -> Void
    private let show: @MainActor () -> Void
    private let status: @MainActor (String?) -> Void
    private var loop: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var active = false
    private var lastPlacement: TilePlacement?
    private var presentationGranted = false

    public init(id: String, reservedHeight: Double,
                registry: TileRegistry = TileRegistry(),
                windowIDs: @escaping @MainActor () -> [UInt32],
                permit: @escaping @MainActor (Bool) -> Void,
                place: @escaping @MainActor (NSRect, String) -> Void,
                show: @escaping @MainActor () -> Void,
                status: @escaping @MainActor (String?) -> Void) {
        store = RegistryWorker(registry: registry)
        member = TileMember(id: id, reservedHeight: reservedHeight)
        self.windowIDs = windowIDs; self.permit = permit; self.place = place
        self.show = show; self.status = status
    }

    public func start(preferredDisplayID: String? = nil) async {
        guard !active else { return }
        active = true; revision &+= 1
        member.preferredDisplayID = preferredDisplayID
        revokePresentation()
        let expected = revision
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active, self.revision == expected else { return }
                await self.reconcile(expected: expected)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    /// Withdraw before releasing the registry slot. Called before the module lease
    /// is handed to Nearpane, so a stale standalone reservation cannot coexist.
    public func stop() async {
        active = false; revision &+= 1
        loop?.cancel(); revokePresentation()
        await loop?.value; loop = nil
        for _ in 0..<20 {
            let observation = Self.observation(members: [member])
            do { try await store.unregister(member, observation); break }
            catch TileCoordinationError.busy {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            } catch { break }
        }
        lastPlacement = nil
    }

    public func invalidateDisplayGeometry() {
        lastPlacement = nil
        revokePresentation()
    }

    private func revokePresentation() { presentationGranted = false; permit(false) }

    /// Dragging changes the display and insertion order in its right-hand column.
    /// It never transfers ownership by heartbeat or moves another app's window.
    public func requestPlacement(displayID: String?, top: Double) async {
        guard active else { return }
        let state = try? await store.snapshot()
        let neighbours = state?.plan.placements.filter { $0.key != member.id && $0.value.displayID == displayID }
            .sorted { $0.value.rect.y < $1.value.rect.y } ?? []
        let before = neighbours.last { $0.value.rect.y < top }
        let order = before.flatMap { state?.members[$0.key]?.userOrder }
        // Give all existing members explicit ranks before inserting. This keeps a
        // newly installed component after a user's order instead of resetting it.
        await stop()
        do { member.userOrder = try await store.insertionOrder(displayID: displayID, top: top) }
        catch { member.userOrder = order.map { $0 + 1 } ?? 0 }
        member.preferredDisplayID = displayID
        await start(preferredDisplayID: displayID)
    }

    private func reconcile(expected: UInt64) async {
        do {
            let state = try await store.snapshot()
            guard active, revision == expected, !Task.isCancelled else { return }
            let screens = Self.screens()
            let observation = Self.observation(members: Array(state.members.values()))
            let obstacles = Self.legacyObstacles(screens: screens, registered: Array(state.members.values()))
            member.windowIDs = windowIDs()
            var plan = try await store.reconcile(member, screens.map(\.display), observation, obstacles)
            guard active, revision == expected, !Task.isCancelled else { return }
            if plan.withdraw.contains(member.id) {
                revokePresentation()
                await Task.yield()
                let fresh = Self.observation(members: Array(state.members.values()))
                plan = try await store.acknowledge(member, plan.generation, fresh)
            }
            guard active, revision == expected, !Task.isCancelled else { return }
            guard plan.mayShow(member.id), let placement = plan.placements[member.id],
                  let screen = screens.first(where: { $0.display.id == placement.displayID }) else {
                revokePresentation()
                if plan.phase == .stable { status("右侧暂时没有足够空间，可将歌词板移到另一个显示器。") }
                return
            }
            if lastPlacement != placement {
                revokePresentation()
                let r = placement.rect, v = screen.visible
                place(NSRect(x: v.minX + r.x, y: v.maxY - r.y - r.height, width: r.width, height: r.height), placement.displayID)
                lastPlacement = placement
            }
            let needsPresentation = !presentationGranted
            permit(true); presentationGranted = true; status(nil)
            if needsPresentation { show() }
        } catch TileCoordinationError.busy {
            // The next bounded reconciliation retries; no blocking flock on AppKit.
        } catch TileCoordinationError.staleGeneration {
            revokePresentation()
        } catch {
            revokePresentation()
            status("桌面排列暂不可用。可在设置中关闭自动排列后重新显示。")
        }
    }

    private struct Screen {
        var display: TileDisplay
        var visible: NSRect
    }
    private static func screens() -> [Screen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let id = CFUUIDCreateString(nil, uuid) as String
            return Screen(display: TileDisplay(id: id, width: screen.visibleFrame.width, height: screen.visibleFrame.height,
                                               isPrimary: number.uint32Value == CGMainDisplayID()), visible: screen.visibleFrame)
        }
    }
    private static func observation(members: [TileMember]) -> TileObservation {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let visible = rows.map { Set($0.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }) }
        var ended = Set<String>()
        for member in members {
            if let token = TileProcess.token(for: member.pid) {
                if token != member.processToken { ended.insert(member.processToken) }
            } else if Darwin.kill(member.pid, 0) == -1 && errno == ESRCH { ended.insert(member.processToken) }
        }
        return TileObservation(visibleWindowIDs: visible, endedProcessTokens: ended)
    }
    private static func legacyObstacles(screens: [Screen], registered: [TileMember]) -> [TilePlacement] {
        let bundles: Set<String> = ["com.riftlet.app", "app.saytile.mac", "app.saytile.mac.mandarin-candidate"]
        let registeredPIDs = Set(registered.map(\.pid))
        let pids = Set(NSWorkspace.shared.runningApplications.filter {
            bundles.contains($0.bundleIdentifier ?? "") && !registeredPIDs.contains($0.processIdentifier)
        }.map(\.processIdentifier))
        guard !pids.isEmpty,
              let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let desktopTop = NSScreen.screens.first?.frame.maxY else { return [] }
        var result: [TilePlacement] = []
        for row in rows {
            guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue, (0...99).contains(layer),
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0.1,
                  (120...520).contains(rect.width), (44...800).contains(rect.height) else { continue }
            let global = NSRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
            for screen in screens where screen.visible.intersects(global) && global.width * global.height < screen.visible.width * screen.visible.height * 0.3 {
                let clipped = screen.visible.intersection(global)
                result.append(TilePlacement(displayID: screen.display.id,
                    rect: TileRect(x: clipped.minX - screen.visible.minX, y: screen.visible.maxY - clipped.maxY,
                                   width: clipped.width, height: clipped.height)))
            }
        }
        return result
    }
}

private actor RegistryWorker {
    let registry: TileRegistry
    init(registry: TileRegistry) { self.registry = registry }
    func snapshot() throws -> TileRegistryState { try registry.snapshot() }
    func reconcile(_ member: TileMember, _ displays: [TileDisplay], _ observation: TileObservation, _ obstacles: [TilePlacement]) throws -> TilePlan {
        try registry.reconcile(member, displays: displays, observation: observation, obstacles: obstacles)
    }
    func acknowledge(_ member: TileMember, _ generation: UInt64, _ observation: TileObservation) throws -> TilePlan {
        try registry.acknowledgeHidden(id: member.id, instanceID: member.instanceID, generation: generation, observation: observation)
    }
    func unregister(_ member: TileMember, _ observation: TileObservation) throws {
        try registry.unregister(id: member.id, instanceID: member.instanceID, observation: observation)
    }
    func insertionOrder(displayID: String?, top: Double) throws -> Int {
        try registry.insertionOrder(displayID: displayID, top: top)
    }
}
