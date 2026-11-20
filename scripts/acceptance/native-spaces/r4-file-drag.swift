// A real AppKit NSDraggingSession. Source and receiver accept one disposable text fixture.
import AppKit
import ApplicationServices
import CryptoKit

private struct Refusal: LocalizedError {
    let errorDescription: String?
    init(_ reason: String) { errorDescription = reason }
}
private final class FixturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class FixtureView: NSView, NSDraggingSource {
    let file: URL
    var entered = false
    var performed = false
    var received: URL?
    var receivedBytes: Data?
    var sent = false
    init(file: URL) {
        self.file = file
        super.init(frame: NSRect(x: 0, y: 0, width: 66, height: 44))
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Nearpane owned drag fixture")
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: file.path))
        sent = true
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { entered = true; return .copy }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        performed = true
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard urls?.count == 1, let url = urls?.first, url.lastPathComponent == file.lastPathComponent else { return false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        receivedBytes = try? Data(contentsOf: url)
        received = url
        return receivedBytes != nil
    }
}

@MainActor private enum Review {
    static func attribute(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(item, name as CFString, &value) == .success ? value : nil
    }
    static func tile(_ host: NSRunningApplication, identifier: String) -> CGRect? {
        let root = AXUIElementCreateApplication(host.processIdentifier)
        var pending = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [], visited = 0
        while let item = pending.popLast(), visited < 800 {
            visited += 1
            if (attribute(item, kAXIdentifierAttribute) as? String)?.hasPrefix(identifier) == true {
                guard let p = attribute(item, kAXPositionAttribute), let s = attribute(item, kAXSizeAttribute),
                      CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { continue }
                var origin = CGPoint.zero, size = CGSize.zero
                if AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) {
                    return CGRect(origin: origin, size: size)
                }
            }
            pending.append(contentsOf: attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return nil
    }
    static func waitTile(_ host: NSRunningApplication, _ identifier: String) async -> CGRect? {
        for _ in 0..<45 {
            if let box = tile(host, identifier: identifier), box.width >= 8, box.height >= 8 { return box }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return nil
    }
    static func drag(_ a: CGPoint, _ b: CGPoint) async throws {
        func post(_ type: CGEventType, _ p: CGPoint) throws {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else {
                throw Refusal("event allocation failed")
            }
            event.post(tap: .cghidEventTap)
        }
        try post(.mouseMoved, a)
        try await Task.sleep(for: .milliseconds(100))
        try post(.leftMouseDown, a)
        defer { try? post(.leftMouseUp, b) }
        try await Task.sleep(for: .milliseconds(160))
        for step in 1...20 {
            let t = CGFloat(step) / 20
            try post(.leftMouseDragged, .init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(220))
    }
    static func run(_ output: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        guard CGPreflightPostEventAccess(), AXIsProcessTrusted(), NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
              let cursor = CGEvent(source: nil)?.location else { throw Refusal("observer input, AX and a single display required") }
        guard let host = NSRunningApplication.runningApplications(withBundleIdentifier: "com.holdsnow.nearpane.alpha")
            .first(where: { $0.bundleURL?.path == "/Applications/Nearpane.app" }),
              let drop = await waitTile(host, "tray-file-drop"), let front = NSWorkspace.shared.frontmostApplication else {
            throw Refusal("installed host and empty file tile required")
        }
        guard tile(host, identifier: "tray-saved-file-") == nil else { throw Refusal("existing file tile") }
        let name = "Nearpane-R4-\(UUID().uuidString.prefix(8)).txt"
        let payload = Data(("Nearpane native tray round trip. " + name + "\n").utf8)
        let file = output.appendingPathComponent(name)
        try payload.write(to: file, options: .withoutOverwriting)
        func ownerAt(_ point: CGPoint) -> pid_t? {
            var node: AXUIElement?, pid: pid_t = 0
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &node) == .success,
                  let node, AXUIElementGetPid(node, &pid) == .success else { return nil }
            return pid
        }
        func exposedPoint(_ box: CGRect) -> CGPoint? {
            let steps = Array(1..<max(2, Int(box.height))).sorted { abs(Double($0) - box.height / 2) < abs(Double($1) - box.height / 2) }
            for x in [0.5, 0.25, 0.75] {
                for step in steps {
                    let p = CGPoint(x: box.minX + box.width * x, y: box.minY + CGFloat(step))
                    if ownerAt(p) == host.processIdentifier { return p }
                }
            }
            return nil
        }
        let receivingArea = tile(host, identifier: "tray-content") ?? drop
        guard let to = exposedPoint(drop) ?? exposedPoint(receivingArea) else { throw Refusal("entire file tile is covered") }
        let fromX = to.x > screen.frame.midX ? screen.frame.midX : screen.frame.midX + 100
        let from = CGPoint(x: fromX, y: to.y)
        let box = NSRect(x: from.x - 33, y: screen.frame.maxY - from.y - 22, width: 66, height: 44)
        guard screen.visibleFrame.contains(box) else { throw Refusal("fixture outside visible display") }
        let fixture = FixtureView(file: file)
        let panel = FixturePanel(contentRect: box, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = fixture
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        try await Task.sleep(for: .milliseconds(300))
        guard ownerAt(from) == getpid(), ownerAt(to) == host.processIdentifier else {
            throw Refusal("owned drag source or installed tile is covered")
        }
        try await drag(from, to)
        guard fixture.sent, let tile = await waitTile(host, "tray-saved-file-") else { throw Refusal("imported file tile absent after real drop") }
        try JSONSerialization.data(withJSONObject: ["importedTile":true, "sourceDragStarted":fixture.sent]).write(to:output.appendingPathComponent("import.json"))
        guard let out = exposedPoint(tile), ownerAt(from) == getpid() else { throw Refusal("export hit tests changed") }
        try await drag(out, from)
        for _ in 0..<25 where fixture.received == nil { try await Task.sleep(for: .milliseconds(100)) }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nearpane Alpha Profiles")
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("profile-index.json"))) as? [String:Any]
        guard let active = index?["active"] as? String, UUID(uuidString:active) != nil else { throw Refusal("active profile missing") }
        let store = support.appendingPathComponent("generations/" + active + "/Nearpane/Tray Files")
        let saved = try fm.contentsOfDirectory(at:store, includingPropertiesForKeys:nil).filter { UUID(uuidString:$0.lastPathComponent) != nil }
            .map { $0.appendingPathComponent(name) }.filter { (try? Data(contentsOf:$0)) == payload }
        let verifiedExport = fixture.receivedBytes == payload
        let diagnostics: [String:Any] = ["entered":fixture.entered,"performed":fixture.performed,"didReceiveURL":fixture.received != nil,
                                         "outboundBytesMatch":verifiedExport,"durableCopiesOfThisFixture":saved.count]
        try JSONSerialization.data(withJSONObject: diagnostics).write(to:output.appendingPathComponent("export.json"))
        guard verifiedExport, saved.count == 1, let saved = saved.first else { throw Refusal("export or persisted copy failed independent byte comparison") }
        let attrs = try fm.attributesOfItem(atPath:saved.deletingLastPathComponent().path)
        guard let savedAt = attrs[.modificationDate] as? Date else { throw Refusal("save time unavailable") }
        panel.orderOut(nil)
        CGWarpMouseCursorPosition(cursor)
        let focus = front.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier
        let end = ContinuousClock.now.advanced(by: .seconds(65))
        while Review.tile(host, identifier: "tray-saved-file-") != nil, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(600)) }
        let expiryAge = Date().timeIntervalSince(savedAt)
        let exited = Review.tile(host, identifier: "tray-saved-file-") == nil && (57...67).contains(expiryAge)
        let persisted = (try? Data(contentsOf: saved)) == payload
        let report: [String: Any] = ["realAppKitImport": true, "realAppKitExport": true, "byteIdentical": true,
            "tileExpired": exited, "secondsSinceSaveAtRemoval": expiryAge, "copiedFileRetainedAfterExpiry": persisted, "focusPreservedDuringDrags": focus,
            "fixtureSHA256": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("result.json"))
        if persisted, (try fm.contentsOfDirectory(at: saved.deletingLastPathComponent(), includingPropertiesForKeys: nil)) == [saved] {
            try fm.removeItem(at: saved)
            try fm.removeItem(at: saved.deletingLastPathComponent())
        }
        guard exited, persisted, focus else { throw Refusal("expiry, persistence or focus failed") }
    }
}
@main struct Entry {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await Review.run(url); exit(0) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(2) }
        }
        NSApplication.shared.run()
    }
}
