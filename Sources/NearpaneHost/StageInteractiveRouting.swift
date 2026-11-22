import AppKit
import Darwin
import NearpaneOrdinaryWindowRuntime

@MainActor enum StageInteractiveRouting {
    struct DockState: Equatable {
        let pid: pid_t, birth: UInt64, miniatures: Int, runningTiles: Int
        var evidence: [String:Any] { ["pid":pid,"birth":birth,"minimizedWindowTiles":miniatures,"applicationTiles":runningTiles] }
        @MainActor static func read() throws -> Self {
            let dock = try StageCanaryOverview.signedDock()
            func value(_ e: AXUIElement,_ attribute: String) -> CFTypeRef? {
                var v: CFTypeRef?
                return AXUIElementCopyAttributeValue(e,attribute as CFString,&v) == .success ? v : nil
            }
            guard let children = value(dock.app,kAXChildrenAttribute) as? [AXUIElement] else { throw StagePairRefusal("dockChildrenUnavailable") }
            let lists = children.filter { value($0,kAXRoleAttribute) as? String == kAXListRole }
            guard lists.count == 1, let list = lists.first, let tiles = value(list,kAXChildrenAttribute) as? [AXUIElement],
                  (1..<1024).contains(tiles.count) else { throw StagePairRefusal("dockTilesUnavailable") }
            let roles = tiles.compactMap { value($0,kAXSubroleAttribute) as? String }
            guard roles.count == tiles.count, roles.contains(kAXApplicationDockItemSubrole) else { throw StagePairRefusal("dockTileRolesMissing") }
            return .init(pid:dock.image.pid,birth:dock.image.launch,miniatures:roles.filter { $0 == kAXMinimizedWindowDockItemSubrole }.count,
                         runningTiles:roles.filter { $0 == kAXApplicationDockItemSubrole }.count)
        }
    }

    static func hasFocus(_ target: StageInteractiveWindows.Bound, pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&value) == .success &&
            value.map { CFEqual($0,target.element) } == true && NearpaneOrdinaryWindowRuntime.number(target.element) == target.row.window
    }

    static func hit(_ target: StageInteractiveWindows.Bound, at point: CGPoint) -> Bool {
        guard target.cg.insetBy(dx:8,dy:30).contains(point) else { return false }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&element) == .success,
              let element else { return false }
        if CFEqual(element,target.element) { return true }
        var owner: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,kAXWindowAttribute as CFString,&owner) == .success &&
            owner.map { CFEqual($0,target.element) } == true
    }

    static func selectOwned(_ target: StageInteractiveWindows.Bound, peer: StageInteractivePeer) async throws {
        guard let pid = peer.image?.pid else { throw StagePairRefusal("fixtureProcessUnavailable") }
        _ = try peer.exchange("focusOwned")
        let end = ContinuousClock.now.advanced(by:.seconds(1))
        while !hasFocus(target,pid:pid) {
            guard ContinuousClock.now < end else { throw StagePairRefusal("fixtureDidNotAcquireExactFocus") }
            try await Task.sleep(for:.milliseconds(20))
        }
    }

    static func clearInput(_ state: StageInteractivePair.InputState, syntheticDown: Bool) throws {
        guard !state.secure, state.hardwareButtons == 0,
              state.sessionButtons == 0 || (syntheticDown && state.sessionButtons == 1) else {
            throw StagePairRefusal("secureInputOrUnattributedMouseButton")
        }
    }

    /// The native worker publishes after two exclusive membership and off-screen reads.
    /// It only returns the target, then releases its lease, after this reply or its bounded timeout.
    static func parked(_ peer: StageInteractivePeer) throws -> Bool {
        let name = peer.directory.appendingPathComponent("interactive-parked").path
        let fd = open(name,O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_RDONLY)
        guard fd >= 0 else { if errno == ENOENT { return false }; throw StagePairRefusal("parkedMarkerUnreadable") }
        var s = stat()
        let file = FileHandle(fileDescriptor: fd,closeOnDealloc:true)
        guard fstat(fd,&s) == 0, s.st_uid == getuid(), s.st_nlink == 1, s.st_mode & S_IFMT == S_IFREG,
              s.st_mode & 0o777 == 0o600 else { throw StagePairRefusal("parkedMarkerIdentityChanged") }
        if s.st_size == 0 { return false }
        guard s.st_size == 36, let bytes = try file.read(upToCount:37), bytes == Data(peer.nonce.uuidString.lowercased().utf8) else {
            throw StagePairRefusal("parkedNonceChanged")
        }
        return true
    }

    static func acknowledge(_ peer: StageInteractivePeer, target: UInt32, receiver: UInt32, status: String) throws {
        let dir = open(peer.directory.path,O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw StagePairRefusal("interactiveDirectoryUnavailable") }
        defer { close(dir) }
        let fd = openat(dir,"interactive-input.pending",O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw StagePairRefusal("parkedInputAlreadyClaimed") }
        let f = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        let row: [String:Any] = ["challenge":peer.nonce.uuidString.lowercased(),"target":target,"receiver":receiver,"status":status]
        try f.write(contentsOf:JSONSerialization.data(withJSONObject:row,options:.sortedKeys))
        try f.synchronize()
        try f.close()
        guard renameatx_np(dir,"interactive-input.pending",dir,"interactive-input.json",UInt32(RENAME_EXCL)) == 0,
              fsync(dir) == 0 else { throw StagePairRefusal("parkedInputReceiptUncertain") }
    }

    static func targetAbsent(_ target: StageInteractiveWindows.Bound, pid: pid_t) -> Bool {
        guard let old = CGWindowListCopyWindowInfo(.optionIncludingWindow,target.row.window) as? [[String:Any]], old.count == 1,
              old[0][kCGWindowOwnerPID as String] as? Int32 == pid,
              let live = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]],
              !live.isEmpty, live.allSatisfy({ $0[kCGWindowNumber as String] as? UInt32 != nil }) else { return false }
        return !live.contains { $0[kCGWindowNumber as String] as? UInt32 == target.row.window }
    }
}
