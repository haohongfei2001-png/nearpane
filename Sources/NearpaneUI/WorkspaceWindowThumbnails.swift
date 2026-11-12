import AppKit
import NearpaneCore
import Observation
import ScreenCaptureKit

/// An in-memory preview for the windows currently projected by one visible sidebar.
@Observable @MainActor final class WorkspaceWindowThumbnails {
    struct WindowKey: Hashable {
        let pid: Int32
        let launch: UInt64
        let number: CGWindowID

        init?(_ window: WindowObservation) {
            guard let m = window.metadata, m.number > 0, m.pid > 1,
                  let launch = m.launchMicroseconds, launch > 0,
                  m.minimized != true, m.isOnscreen != false else { return nil }
            pid = m.pid
            number = m.number
            self.launch = launch
        }

        func permits(_ population: DesktopReadPopulation) -> Bool {
            population == .markedFixture ? pid == getpid() : pid != getpid()
        }

        func stillMatches(_ rect: CGRect) -> Bool {
            guard AdmissionBirth.read(pid)?.start == launch,
                  let row = (CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]])?
                    .first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number }),
                  (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let sharing = row[kCGWindowSharingState as String] as? NSNumber,
                  sharing.uint32Value != CGWindowSharingType.none.rawValue,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
            return frame == rect
        }
    }

    private struct Entry {
        let image: CGImage
        let frame: CGRect
        let sampled: TimeInterval
    }

    private var entries: [WindowKey: Entry] = [:]
    @ObservationIgnored private var generation: UInt64 = 0

    func image(for window: WindowObservation) -> CGImage? {
        guard let key = WindowKey(window), let entry = entries[key],
              entry.frame == Self.frame(of: window) else { return nil }
        return entry.image
    }

    func clear() {
        generation &+= 1
        if !entries.isEmpty { entries.removeAll() }
    }

    private static func frame(of window: WindowObservation) -> CGRect? {
        guard let bounds = window.metadata?.globalFrame else { return nil }
        let rect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    func refresh(_ windows: [WindowObservation], population: DesktopReadPopulation) async {
        generation &+= 1
        let current = generation
        guard !Task.isCancelled, !windows.isEmpty, CGPreflightScreenCaptureAccess() else {
            clear()
            return
        }
        // A 384-pixel long edge and a bounded inventory keep resident previews below 14 MiB.
        let candidates = windows.compactMap { window -> (WindowKey, CGRect)? in
            guard let key = WindowKey(window), key.permits(population),
                  let rect = Self.frame(of: window) else { return nil }
            return (key, rect)
        }.prefix(24)
        let allowed = Set(candidates.map { $0.0 })
        for key in entries.keys where !allowed.contains(key) { entries.removeValue(forKey: key) }

        let uptime = ProcessInfo.processInfo.systemUptime
        let due = candidates.filter { key, rect in
            guard let entry = entries[key] else { return true }
            return entry.frame != rect || uptime - entry.sampled >= 10
        }
        guard !due.isEmpty else { return }
        do {
            let content: SCShareableContent
            if population == .markedFixture {
                guard #available(macOS 14.4, *) else { clear(); return }
                content = try await SCShareableContent.currentProcess
            } else {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            }
            guard generation == current, !Task.isCancelled else { return }
            for (key, rect) in due {
                guard generation == current, !Task.isCancelled else { return }
                guard CGPreflightScreenCaptureAccess() else { clear(); return }
                guard let window = content.windows.first(where: {
                    $0.windowID == key.number && $0.owningApplication?.processID == key.pid
                        && $0.windowLayer == 0 && $0.isOnScreen && $0.frame == rect
                }), key.stillMatches(rect) else {
                    entries.removeValue(forKey: key)
                    continue
                }
                let config = SCStreamConfiguration()
                let scale = min(1, 384 / max(rect.width, rect.height))
                config.width = max(1, Int((rect.width * scale).rounded()))
                config.height = max(1, Int((rect.height * scale).rounded()))
                config.preservesAspectRatio = true
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                if #available(macOS 14.2, *) { config.includeChildWindows = false }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard generation == current, !Task.isCancelled else { return }
                guard CGPreflightScreenCaptureAccess() else { clear(); return }
                if let image, key.stillMatches(rect) {
                    entries[key] = Entry(image: image, frame: rect, sampled: ProcessInfo.processInfo.systemUptime)
                } else {
                    entries.removeValue(forKey: key)
                }
            }
        } catch {
            if generation == current { clear() }
        }
    }
}
