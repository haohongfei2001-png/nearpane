import AppKit
import ApplicationServices
import Darwin
import NearpaneCore
import NearpaneWindowEngine

/// The R4 drop supplies exact source and destination window identities. Apple changes its own stages.
@MainActor enum AppleStageMerge {
    typealias Members = Set<DesktopWindowKey>
    struct Observation {
        let timestamp: UInt64
        let settled: Bool
        let current: Members
        /// Complete, independently read WindowManager AX strip items; never inferred from card positions.
        let strip: [Members]
        let point: AppleStageMergePoint?
    }
    enum Failure: Error, Equatable { case unqualified, interrupted, unavailable, unconfirmed, busy }
    private static var dispatching = false

    static var isQualified: Bool { AppleStageProductAdmission.permits(.merge) }

    /// Scope and input generation are checked again by the caller on every asynchronous return.
    /// Readback cannot infer a transfer from focus or a successful event post.
    static func perform(source: Members, destination: Members, stillCurrent: @escaping @MainActor () -> Bool,
                        observe: @escaping @MainActor (Members, Members) async -> Observation?) async throws {
        let production = isQualified
        #if DEBUG
        let lab = !production && AppleStageMergeFixture.consume(source,destination)
        guard production || lab else { throw Failure.unqualified }
        var verified = false
        defer { if lab { AppleStageMergeFixture.finish(verified) } }
        let allowed = { @MainActor in stillCurrent() && (!lab || AppleStageMergeFixture.permitsLiveWrites()) }
        #else
        guard production else { throw Failure.unqualified }
        let allowed = stillCurrent
        #endif
        guard !dispatching else { throw Failure.busy }
        guard !source.isEmpty, !destination.isEmpty, source.isDisjoint(with: destination),
              source.count <= 32 else { throw Failure.unavailable }
        dispatching = true
        defer { dispatching = false }
        var remaining = source, active = destination
        var protectedStrip: Set<Members>?
        while !remaining.isEmpty {
            guard safe(allowed) else { throw Failure.interrupted }
            guard let before = await observe(remaining, active), safe(allowed), before.settled,
                  let point = before.point, point.timestamp == before.timestamp,
                  let target = remaining.first(where: { $0.number == point.window }),
                  within(before.timestamp, milliseconds: 400),
                  let rest = preserved(before, current: active, source: remaining),
                  protectedStrip == nil || protectedStrip == rest else { throw Failure.unavailable }
            #if DEBUG
            if lab { AppleStageMergeFixture.note("before",before) }
            #endif
            protectedStrip = rest
            try await press(point, windows: Set(remaining.map(\.number)), stillCurrent: allowed)
            let oldActive = active, oldSource = remaining
            remaining.remove(target)
            active.insert(target)
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            var confirmed = 0
            var last = before.timestamp
            while confirmed < 2 {
                guard safe(allowed) else { throw Failure.interrupted }
                guard ContinuousClock.now < deadline else { throw Failure.unconfirmed }
                try await Task.sleep(for: .milliseconds(80))
                guard let after = await observe(remaining, active), safe(allowed),
                      after.timestamp > last else { throw Failure.unconfirmed }
                #if DEBUG
                if lab { AppleStageMergeFixture.note("readback",after) }
                #endif
                last = after.timestamp
                guard after.settled else { confirmed = 0; continue }
                if preserved(after, current: active, source: remaining) == rest {
                    confirmed += 1
                } else if preserved(after, current: oldActive, source: oldSource) == rest {
                    confirmed = 0
                } else { throw Failure.unconfirmed }
            }
        }
        #if DEBUG
        verified = true
        #endif
    }

    /// Returns the unaffected partition only when native memberships are disjoint and exact.
    static func preserved(_ observation: Observation, current: Members, source: Members) -> Set<Members>? {
        guard observation.current == current, observation.settled else { return nil }
        var covered = current
        var others = Set<Members>()
        var found = source.isEmpty
        for group in observation.strip {
            guard !group.isEmpty, covered.isDisjoint(with: group) else { return nil }
            covered.formUnion(group)
            if group == source { found = true } else { others.insert(group) }
        }
        return found ? others : nil
    }

    private static func within(_ time: UInt64, milliseconds: UInt64) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return time <= now && now - time <= milliseconds * 1_000_000
    }
    private static func safe(_ current: @MainActor () -> Bool) -> Bool {
        current() && !Task.isCancelled && WindowContentPreview.sessionAvailable() &&
            StageManagerPreference.read() == true && NSEvent.pressedMouseButtons == 0
    }
    private static func press(_ point: AppleStageMergePoint, windows: Set<UInt32>,
                              stillCurrent: @escaping @MainActor () -> Bool) async throws {
        // Upstream post::shift_press. Flags on the mouse event alone may switch to
        // another stage. A real Shift press is owned and released for this click.
        let forbidden: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn]
        let moveTypes: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        func moves() -> [UInt32] { moveTypes.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) } }
        guard safe(stillCurrent), CGPreflightPostEventAccess(), CGPreflightListenEventAccess(), AXIsProcessTrusted(),
              CGEventSource.flagsState(.hidSystemState).intersection(forbidden).isEmpty,
              CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) >= 0.15,
              moveTypes.allSatisfy({ CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) >= 0.05 }),
              point.stillHits(windows), within(point.timestamp, milliseconds: 500),
              let origin = CGEvent(source: nil)?.location, let src = CGEventSource(stateID: .privateState),
              let shiftDown = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true),
              let shiftUp = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false),
              let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point.location, mouseButton: .left),
              let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point.location, mouseButton: .left)
        else { throw Failure.unavailable }
        let initialMoves = moves()
        let input = NativeSelectionPermit.inputCounters()
        shiftDown.flags = .maskShift
        shiftUp.flags = []
        down.flags = .maskShift
        up.flags = .maskShift
        guard safe(stillCurrent) else { throw Failure.interrupted }
        shiftDown.post(tap: .cghidEventTap)
        defer { shiftUp.post(tap: .cghidEventTap) }
        try await Task.sleep(for: .milliseconds(12))
        guard safe(stillCurrent), moves() == initialMoves, input == NativeSelectionPermit.inputCounters(),
              point.stillHits(windows), within(point.timestamp, milliseconds: 550), CGPreflightPostEventAccess(),
              CGEventSource.flagsState(.hidSystemState).intersection([.maskControl, .maskCommand, .maskAlternate]).isEmpty
        else { throw Failure.interrupted }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // Queue processing may follow the post. Warp back only when the pointer actually
        // reached the posted coordinate and the user has not since moved it.
        let limit = ContinuousClock.now.advanced(by: .milliseconds(18))
        while ContinuousClock.now < limit, moves() == initialMoves {
            if let at = CGEvent(source: nil)?.location, hypot(at.x-point.location.x, at.y-point.location.y) <= 1.5 {
                if hypot(origin.x-point.location.x, origin.y-point.location.y) > 1.5 {
                    _ = CGWarpMouseCursorPosition(origin)
                }
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(12))
    }
}
