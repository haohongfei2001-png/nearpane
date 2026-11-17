import AppKit
import NearpaneCore
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Native acceptance only. The Host verifies the running, separately signed disposable
/// application before entry. Both visible windows contain only enrolled synthetic content.
private final class PreviewReadbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@available(macOS 15.2, *)
@MainActor public enum SelectedPreviewReadback {
    public static func run(owner: AdmissionFixtureOwner, number: UInt32, support: URL) async throws -> Data {
        guard owner.kind == .documents, number > 0, CGPreflightScreenCaptureAccess(),
              let screen = NSScreen.screens.first, NSScreen.screens.count == 1,
              let geometry = SystemScreens.geometry().first else { throw OrdinaryWindowFailure("No existing ScreenCaptureKit permission or single display.") }
        guard let originalFront = NSWorkspace.shared.frontmostApplication?.processIdentifier, originalFront != getpid() else {
            throw OrdinaryWindowFailure("No unrelated foreground to preserve.")
        }
        let host = HostSession(store: MemoryConfigurationStore(), includeSampleModules: false)
        await host.start()
        defer { host.stop() }
        host.bus.resetDesktopSession()
        let reader = WindowAdmissionReader(support: support, fixtureOnly: true, owners: [owner])
        let selection = AdmissionSelection(reader: reader)
        selection.open()
        defer { selection.close() }
        guard selection.apps.count == 1, let app = selection.apps.first else { throw OrdinaryWindowFailure("Could not confirm the enrolled fixture process.") }
        await selection.select(app)
        guard selection.choices.count == 1, let choice = selection.choices.first, choice.number == number,
              let handle = reader.handle(choice, app: app) else { throw OrdinaryWindowFailure("Original AX element unavailable: \(selection.failure ?? "window helper did not hold the one selected window").") }
        selection.toggle(choice)
        let begin = Date()
        let pair = try await handle.prepare()
        let sample = pair.second
        guard let frame = sample.cgFrame, sample.axFrame == frame, sample.axNumber == number,
              sample.display == geometry.id, let selected = selection.ruleID, selected == handle.id else { throw OrdinaryWindowFailure("The retained fixture window did not corroborate its CG/AX geometry.") }
        let observed = WindowObservation(id: choice.id.uuidString, displayID: geometry.id, bounds: frame, membership: .unknown,
            confidence: .corroboratedMetadata, metadata: .init(number: number, pid: owner.pid, launchMicroseconds: owner.launch,
                element: selected.element, globalFrame: frame, frontToBack: 0, minimized: sample.minimized, fullScreen: sample.fullscreen,
                axFrame: sample.axFrame, isOnscreen: sample.onScreen, axStandardWindowNumber: sample.axNumber))
        let size = screen.frame.size
        let usable = screen.visibleFrame
        let observation = DisplayObservation(id: geometry.id, frame: .init(width: size.width, height: size.height),
            rotationDegrees: Int(geometry.rotationDegrees), backingScale: screen.backingScaleFactor,
            usable: .init(x: usable.minX, y: size.height - usable.maxY, width: usable.width, height: usable.height))
        // Only the attributed test window enters the fixture bus. Its AX/CG geometry is
        // read above; this experiment makes no claim about its desktop membership.
        let snapshot = DesktopSnapshot.observed(.init(session: UUID(), revision: 1, parentPID: getpid(),
            fixtureWindows: [number], anchors: [], experimentalSpaces: false), from: begin, to: Date(), build: ProcessInfo.processInfo.operatingSystemVersionString,
            topology: geometry.id, consistent: true, separateSpaces: NSScreen.screensHaveSeparateSpaces,
            displays: [observation], scopes: [], windows: [observed], evidence: .init(population: .markedFixture,
                accessibility: .available, spaces: .disabled, rows: [], windowLimitReached: false,
                beganUptime: pair.first.uptime, endedUptime: sample.uptime))
        guard host.bus.acceptDesktop(snapshot) else { throw OrdinaryWindowFailure("The fixture observation failed validation.") }
        let previews = WindowContentPreview(), display = SurfaceDisplay(), pointer = WorkspacePointerRegistry()
        display.id = geometry.id; display.interactionVisible = true; display.pointer = pointer
        pointer.windowPreviews = previews
        previews.setVisible(true, on: geometry.id)
        // Production DisplayPanels owns the registry. Keep the same lifetime while
        // the acceptance surface holds its normal weak routing reference.
        defer { pointer.windowPreviews = nil; previews.clear() }
        let rect = CGRect(x: usable.minX + 8, y: usable.minY + 8, width: 340, height: 240)
        guard usable.contains(rect) else { throw OrdinaryWindowFailure("No safe test panel area.") }
        let view = NSHostingView(rootView: DesktopSurface(host: host, displayID: geometry.id,
            enabled: true, display: display).frame(width: rect.width, height: rect.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = PreviewReadbackPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.hidesOnDeactivate = false; window.ignoresMouseEvents = true; window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.canJoinAllApplications]
        window.setFrame(rect, display: false)
        defer { window.orderOut(nil); window.close() }
        func safe() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFront &&
                NSScreen.screens.count == 1 && screen.visibleFrame == usable && usable.contains(window.frame) &&
                !NSApp.isActive && !window.isMainWindow && !window.isKeyWindow
        }
        guard safe() else { throw OrdinaryWindowFailure("Focus or display changed before presentation.") }
        window.orderBack(nil)
        func panelPixels() async throws -> [Int] {
            try await Task.sleep(for: .milliseconds(320))
            guard safe(), window.isVisible, window.windowNumber > 0 else {
                throw OrdinaryWindowFailure("Test panel focus or placement changed.")
            }
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            // The only readback ID is the Host's own opaque panel. The filter never
            // samples another app, the desktop underneath it, or the whole display.
            let content = try await SCShareableContent.currentProcess
            let matches = content.windows.filter { $0.windowID == UInt32(window.windowNumber) && $0.owningApplication?.processID == getpid() }
            guard matches.count == 1, let own = matches.first, own.isOnScreen else {
                throw OrdinaryWindowFailure("The system could not identify the Host's own test panel.")
            }
            let config = SCStreamConfiguration()
            config.width = Int(rect.width); config.height = Int(rect.height)
            config.ignoreShadowsSingleWindow = true; config.includeChildWindows = false; config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
            guard safe() else { throw OrdinaryWindowFailure("Focus changed during panel readback.") }
            return try colors(in: image)
        }
        let before = try await panelPixels()
        await selection.photograph(using: previews, host: host)
        let acquired = previews.image(in: snapshot)
        let received = acquired != nil && previews.binding?.number == number && previews.revision == snapshot.revision
        let source = try acquired.map(colors) ?? []
        let message = previews.notice
        let after = try await panelPixels()
        previews.setVisible(false, on: geometry.id)
        let cleared = try await panelPixels()
        return try JSONSerialization.data(withJSONObject: ["received": received, "notice": message, "before": before,
            "source": source, "after": after, "cleared": cleared, "number": number, "panelNumber": window.windowNumber, "panelPID": getpid(),
            "width": frame.width, "height": frame.height, "panelKey": window.isKeyWindow, "panelMain": window.isMainWindow,
            "pass": received && source.count == 2 && source.allSatisfy { $0 >= 8 } &&
                before == [0, 0] && after.allSatisfy { $0 >= 8 } && cleared == [0, 0]], options: [.sortedKeys])
    }

    /// Count only the two known fixture colors; never persist source images or render output.
    private static func colors(in image: CGImage) throws -> [Int] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let raster = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let buffer = raster.data else { throw OrdinaryWindowFailure("sRGB readback unavailable.") }
        raster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        var result = [0, 0]
        for i in stride(from: 0, to: image.width * image.height * 4, by: 4) where bytes[i+3] >= 245 {
            let r = Int(bytes[i]), g = Int(bytes[i+1]), b = Int(bytes[i+2])
            if abs(r-31) <= 10 && abs(g-191) <= 10 && abs(b-77) <= 10 { result[0] += 1 }
            if abs(r-204) <= 10 && abs(g-31) <= 10 && abs(b-153) <= 10 { result[1] += 1 }
        }
        return result
    }
}
