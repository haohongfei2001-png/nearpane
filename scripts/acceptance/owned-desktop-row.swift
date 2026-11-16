import AppKit
import NearpaneCore
import NearpaneUI
import WindowGeometryCore
import CReadOnlySpaces

// Run as a disposable accessory bundle with the packaged reader. This process owns every
// described window. It never activates an application, requests permissions or posts input.
private final class WitnessWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct Refused: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

@MainActor private final class Trial: NSObject, NSApplicationDelegate {
    private let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    private var windows = [WitnessWindow]()
    private var activity: NSObjectProtocol?
    private var activationChanged = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var result: [String: Any] = [:]
            do { try await observe(&result) } catch { result["failure"] = String(describing: error) }
            let numbers = windows.map { CGWindowID($0.windowNumber) }
            result["ownedNumbers"] = numbers
            for window in windows { window.orderOut(nil); window.close() }
            result["closedByOwner"] = windows.allSatisfy { !$0.isVisible }
            windows.removeAll()
            try? await Task.sleep(for: .milliseconds(250))
            if let activity { NSWorkspace.shared.notificationCenter.removeObserver(activity) }
            result["registeredBeforeOwnerExit"] = numbers.map { NPReadWindowNumberPresence($0) }
            result["frontmostPreserved"] = front != nil && !activationChanged && front == NSWorkspace.shared.frontmostApplication?.processIdentifier
            let ok = result["failure"] == nil && result["closedByOwner"] as? Bool == true && result["frontmostPreserved"] as? Bool == true
            result["passed"] = ok
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardOutput.write(data)
            }
            exit(ok ? 0 : 3)
        }
    }

    private func observe(_ result: inout [String: Any]) async throws {
        guard let front, front != getpid(), NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
              !NSApp.isActive else { throw Refused("requires one display and an inactive fixture") }
        activity = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] event in
                let pid = (event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { if pid != front { self?.activationChanged = true } }
            }
        let safe = screen.visibleFrame
        for offset in [0, 48] {
            let window = WitnessWindow(contentRect: .zero, styleMask: [.titled, .resizable, .miniaturizable, .closable],
                                       backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.managed, .ignoresCycle]
            window.title = "Nearpane geometry witness"
            window.backgroundColor = offset == 0 ? .systemTeal : .systemOrange
            let frame = NSRect(x: floor(safe.midX) + CGFloat(offset), y: floor(safe.midY) + CGFloat(offset / 2),
                               width: 164, height: 106)
            guard safe.contains(frame) else { throw Refused("fixture geometry outside active display") }
            window.setFrame(frame, display: false)
            windows.append(window)
            window.orderFrontRegardless()
        }
        try await Task.sleep(for: .milliseconds(450))
        let numbers = windows.map { UInt32($0.windowNumber) }
        guard Set(numbers).count == 2, let top = numbers.last,
              let reader = NativeDesktopProvider.packaged(fixtureWindows: { self.windows }) as? any LiveDesktopObservationProvider
        else { throw Refused("sealed desktop reader unavailable") }
        var previous: String?
        var samples = [[String: Any]]()
        for _ in 0..<2 {
            guard !activationChanged, NSWorkspace.shared.frontmostApplication?.processIdentifier == front,
                  windows.allSatisfy({ !$0.isKeyWindow && !$0.isMainWindow && $0.isOnActiveSpace && $0.screen == screen })
            else { throw Refused("focus, display or active Space changed") }
            let snapshot = try await reader.snapshot(experimentalSpaces: true)
            let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
            result["lastEvidence"] = ["rows": snapshot.native?.rows.count ?? -1, "windows": snapshot.windows.count,
                                      "spaceStatus": snapshot.native?.spaces.rawValue ?? "missing",
                                      "accessibility": snapshot.native?.accessibility.rawValue ?? "missing",
                                      "freshness": snapshot.freshness.rawValue]
            guard let evidence = snapshot.native, evidence.rows.count == 1, let witness = evidence.rows.first,
                  evidence.population == .markedFixture, witness.anchor.witness == .ownedWindow,
                  numbers.contains(witness.anchor.number), let display = snapshot.displays.first, let usable = display.usable,
                  snapshot.displays.count == 1, display.id == witness.displayID,
                  let preview = DesktopPreview(snapshot: snapshot, displayID: display.id,
                      viewport: SurfaceRect(x: 0, y: 0, width: 256, height: 160), now: now, uptime: uptime, restrictToDisplay: true),
                  preview.rows.count == 1, let row = preview.rows.first, row.kind == .witnessedSpace(witness.recordID),
                  row.windows.count == 2, snapshot.windows.count == 2,
                  previous == nil || previous == witness.recordID else { throw Refused("no stable witnessed current desktop") }
            var maxError = 0.0, axReads = 0
            for (index, window) in windows.enumerated() {
                let actual = window.frame
                let cg = Rect(actual.minX, screen.frame.maxY - actual.maxY, actual.width, actual.height)
                guard let observed = snapshot.windows.first(where: { $0.metadata?.number == numbers[index] }),
                      let metadata = observed.metadata, metadata.pid == getpid(),
                      observed.membership == .known(recordIDs: [witness.recordID]),
                      let shape = row.windows.first(where: { $0.id == observed.id }) else { throw Refused("window not in witnessed desktop") }
                maxError = max(maxError, cg.componentError(from: metadata.globalFrame.geometry))
                if let ax = metadata.axFrame {
                    maxError = max(maxError, cg.componentError(from: ax.geometry))
                    axReads += 1
                }
                let scale = row.desktop.width / usable.width
                let mapped = Rect(row.desktop.x + (cg.x - display.frame.x - usable.x) * scale,
                                  row.desktop.y + (cg.y - display.frame.y - usable.y) * scale,
                                  cg.width * scale, cg.height * scale)
                maxError = max(maxError, mapped.componentError(from: shape.frame.geometry))
            }
            guard maxError <= 0.01, let frontShape = row.windows.first, let backShape = row.windows.last,
                  let overlap = frontShape.frame.geometry.intersection(backShape.frame.geometry),
                  snapshot.windows.first(where: { $0.id == frontShape.id })?.metadata?.number == top else {
                throw Refused("geometry, overlap or stacking order differs from owner")
            }
            let hit = preview.hit(x: overlap.x + overlap.width / 2, y: overlap.y + overlap.height / 2,
                                  current: snapshot, now: now, uptime: uptime)
            guard hit == .candidate(frontShape.id) || hit == .blocked(frontShape.id) else { throw Refused("wrong overlapping hit region") }
            samples.append(["revision": snapshot.revision, "record": witness.recordID, "localWindowNumbers": numbers,
                            "axFrames": axReads, "maxComponentErrorPoints": maxError, "frontmostHitCorrect": true,
                            "recordsInScope": snapshot.scopes.flatMap(\.records).count])
            result["samples"] = samples
            previous = witness.recordID
            try await Task.sleep(for: .milliseconds(150))
        }
    }
}

@main private enum OwnedDesktopRow {
    @MainActor static func main() {
        let args = CommandLine.arguments.dropFirst()
        if args.first == "--confirm-closed", args.count == 3 {
            let ids = args.dropFirst().compactMap(UInt32.init)
            guard ids.count == 2, Set(ids).count == 2, !ids.contains(0) else { exit(2) }
            let gone = ids.allSatisfy { NPReadWindowNumberPresence($0) == 0 }
            print(gone ? "Both WindowServer IDs retired after owner exit." : "WindowServer IDs not retired.")
            exit(gone ? 0 : 3)
        }
        guard args.isEmpty else { exit(2) }
        let app = NSApplication.shared
        guard Bundle.main.bundleIdentifier == "org.nearpane.acceptance.OwnedDesktopRow" else {
            FileHandle.standardError.write(Data("Wrong fixture bundle\n".utf8)); exit(2)
        }
        if app.activationPolicy() != .accessory { _ = app.setActivationPolicy(.accessory) }
        guard app.activationPolicy() == .accessory else {
            FileHandle.standardError.write(Data("Background activation policy unavailable\n".utf8)); exit(2)
        }
        let trial = Trial()
        app.delegate = trial
        withExtendedLifetime(trial) { app.run() }
    }
}
