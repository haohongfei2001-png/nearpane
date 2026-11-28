import AppKit

/// Geometry of the frozen interactive fixture. Reads only numeric ownership and bounds.
@MainActor struct StageInteractiveFootprint {
    struct Window: Equatable {
        let pid: pid_t
        let number: CGWindowID
        let frame: CGRect
    }

    let proposed: [CGRect]
    let windows: [Window]
    let uptime: TimeInterval

    /// The fixture uses these content rectangles in AppKit coordinates and reports full
    /// decorated window frames in WindowServer coordinates (top-left of the primary display).
    static func project(screen: CGRect, visible: CGRect, includeBystander: Bool = false, outerFrame: (CGRect) -> CGRect) throws -> [CGRect] {
        let width = min(264, floor((visible.width - 60) / 2)), height = min(180, visible.height - 120)
        guard screen.contains(visible), width >= 124, height >= 92 else { throw StagePairRefusal("fixtureScreenGeometryUnavailable") }
        let frames = try (0..<(includeBystander ? 3 : 2)).map { i -> CGRect in
            let content = CGRect(x: visible.minX + 20 + CGFloat(i % 2) * (width + 12),
                                 y: visible.maxY - 60 - height - (i == 2 ? height + 60 : 0),
                                 width: width, height: height)
            let outer = outerFrame(content)
            guard finite(outer), outer.contains(content), screen.contains(outer) else { throw StagePairRefusal("fixtureOuterFrameUnavailable") }
            return CGRect(x: outer.minX, y: screen.maxY - outer.maxY, width: outer.width, height: outer.height)
        }
        guard frames.indices.allSatisfy({ i in frames.prefix(i).allSatisfy { !frames[i].intersects($0) } }) else { throw StagePairRefusal("proposedFixtureFramesOverlap") }
        return frames
    }

    private static func finite(_ r: CGRect) -> Bool {
        [r.origin.x, r.origin.y, r.size.width, r.size.height].allSatisfy(\.isFinite) && r.size.width >= 0 && r.size.height >= 0
    }

    init(proposed: [CGRect], windows: [Window], foregroundPID: pid_t, foregroundWindow: CGWindowID, uptime: TimeInterval) throws {
        guard (2...3).contains(proposed.count), proposed.allSatisfy({ Self.finite($0) && !$0.isEmpty }),
              windows.allSatisfy({ $0.pid > 0 && $0.number != 0 && Self.finite($0.frame) }),
              Set(windows.map(\.number)).count == windows.count else { throw StagePairRefusal("fixtureCensusIncompleteOrDuplicated") }
        guard windows.contains(where: { $0.pid == foregroundPID && $0.number == foregroundWindow && !$0.frame.isEmpty })
        else { throw StagePairRefusal("fixtureCensusMissingHeldForeground") }
        self.proposed = proposed
        self.windows = windows
        self.uptime = uptime
    }

    static func sample(display: String, foregroundPID: pid_t, foregroundWindow: CGWindowID, includeBystander: Bool = false) throws -> Self {
        let screens = NSScreen.screens
        guard screens.count == 1, let screen = screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let current = CFUUIDCreateString(nil, uuid) as String?,
              let expected = UUID(uuidString: display), UUID(uuidString: current) == expected
        else { throw StagePairRefusal("fixtureCensusDisplayChanged") }
        let proposed = try project(screen: screen.frame, visible: screen.visibleFrame, includeBystander: includeBystander) {
            NSWindow.frameRect(forContentRect: $0, styleMask: [.titled, .closable, .resizable, .miniaturizable])
        }
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { throw StagePairRefusal("fixtureWindowServerCensusUnavailable") }
        let windows = try rows.map { row -> Window in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32, let number = row[kCGWindowNumber as String] as? UInt32,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { throw StagePairRefusal("fixtureCensusMissingNumericWindowFields") }
            return Window(pid: pid, number: number, frame: frame)
        }
        return try Self(proposed: proposed, windows: windows, foregroundPID: foregroundPID, foregroundWindow: foregroundWindow,
                        uptime: ProcessInfo.processInfo.systemUptime)
    }

    /// During setup no window can occupy either area. After opening, only the two
    /// signed socket's exact IDs, owner and independently read full frames can be exempt.
    func assess(previous: Self?, registered: [Window] = []) -> (reason: String?, evidence: [String: Any]) {
        let matched = registered.filter { expected in
            windows.contains { actual in
                actual.pid == expected.pid && actual.number == expected.number &&
                    StageInteractiveWindows.equalFrame(actual.frame, expected.frame)
            }
        }
        let owned = Set(matched.map(\.number))
        let other = windows.filter { !owned.contains($0.number) }
        let collisions = proposed.map { frame in
            // Independent numeric geometry can round an origin and size by up to 0.75 pt each.
            let protected = frame.insetBy(dx: -1.5, dy: -1.5)
            return other.filter { !$0.frame.isEmpty && protected.intersects($0.frame) }.count
        }
        let matches = previous.map { $0.proposed == proposed && $0.windows == other }
        let reason: String?
        if !registered.isEmpty && (!(2...proposed.count).contains(registered.count) || owned.count != registered.count ||
            registered[0].pid != registered[1].pid || (registered.count == 3 && registered[0].pid == registered[2].pid) ||
            !zip(proposed, registered).allSatisfy({ StageInteractiveWindows.equalFrame($0, $1.frame) })) {
            reason = "fixtureCensusRegisteredPairDisagrees"
        } else if collisions.contains(where: { $0 > 0 }) {
            reason = "unregisteredOnscreenWindowIntersectsFixture"
        } else if matches == false {
            reason = "fixtureWindowCensusChanged"
        } else {
            reason = nil
        }
        var evidence: [String: Any] = ["uptime": uptime, "proposedOuterFrames": proposed.map { [$0.minX, $0.minY, $0.width, $0.height] },
                                       "onscreenCount": windows.count, "registeredMatches": owned.count, "otherIntersections": collisions]
        if let matches { evidence["sameExternalCensus"] = matches }
        if let reason { evidence["reason"] = reason }
        return (reason, evidence)
    }
}
