import AppKit
import ScreenCaptureKit

@MainActor private func settingsControlSample() -> [String: Any] {
    let front = NSWorkspace.shared.frontmostApplication
    var result: [String: Any] = ["frontmost": front?.bundleIdentifier ?? "unknown"]
    guard front?.bundleIdentifier == "com.apple.systempreferences", let pid = front?.processIdentifier,
          let raw = ax(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return result }
    var queue = [raw as! AXUIElement], seen = Set<AXUIElement>(), controls = [[String: String]](), otherOptions = [String: String]()
    while let el = queue.popLast(), seen.count < 1600 {
        guard seen.insert(el).inserted else { continue }
        let role = ax(el, kAXRoleAttribute) as? String
        let id = ax(el, kAXIdentifierAttribute) as? String ?? ""
        if role == kAXCheckBoxRole || id.lowercased().contains("desktop") || id.contains("stage-manager") {
            var owner: pid_t = 0
            AXUIElementGetPid(el, &owner)
            var control = ["id": id, "role": role ?? "unknown",
                           "owner": NSRunningApplication(processIdentifier: owner)?.bundleIdentifier ?? "unknown"]
            if role == kAXCheckBoxRole {
                control["title"] = ax(el, kAXTitleAttribute) as? String
                control["label"] = ax(el, kAXDescriptionAttribute) as? String
                control["enabled"] = DesktopItemsSetting.boolean(ax(el, kAXEnabledAttribute)).map(String.init) ?? "unreadable"
                control["checked"] = DesktopItemsSetting.boolean(ax(el, kAXValueAttribute)).map(String.init) ?? "unreadable"
                var actions: CFArray?
                AXUIElementCopyActionNames(el, &actions)
                control["pressable"] = String((actions as? [String])?.contains(kAXPressAction) == true)
                if !id.contains("widget"), [control["title"], control["label"]].contains("In Stage Manager") {
                    otherOptions["itemsInStageManager"] = control["checked"]
                }
            }
            controls.append(control)
            if ["stage-manager-on", "click-wallpaper-to-reveal-desktop", "show-desktop-widgets", "show-stage-manager-widgets"].contains(id),
               let value = ax(el, kAXValueAttribute) {
                otherOptions[id] = (value as? NSNumber)?.stringValue ?? value as? String
            }
        }
        if ![kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole, kAXImageRole, "AXWebArea"].contains(role ?? "") {
            queue.append(contentsOf: ax(el, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
    }
    result["visited"] = seen.count; result["desktopControls"] = controls; result["otherOptions"] = otherOptions
    return result
}

private struct DesktopTrialStop: Error {
    let status: String, reason: String
    init(_ status: String, _ reason: String) { self.status = status; self.reason = reason }
}

/// Search the actual composited display for the two adjacent colors of our disposable file icon.
/// Only pixel counts and the marker position leave this function.
private func desktopMarkerPixels(_ display: SCDisplay) async throws -> (count: Int, center: CGPoint?) {
    let cfg = SCStreamConfiguration()
    cfg.width = display.width; cfg.height = display.height; cfg.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
    let w = image.width, h = image.height
    guard w > 4, h > 0, w <= 8192, h <= 8192, let space = CGColorSpace(name: CGColorSpace.sRGB),
          let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
              space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
          let bytes = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { throw DesktopTrialStop("UNKNOWN", "pixelBuffer") }
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    defer { withExtendedLifetime(bitmap) {} }
    var n = 0, xSum = 0, ySum = 0
    for y in stride(from: 0, to: h, by: 2) {
        for x in 0..<(w-4) {
            let i = (y*w+x)*4
            if bytes[i] > 200, bytes[i+1] < 65, bytes[i+2] > 145,
               bytes[i+16] < 65, bytes[i+17] > 200, bytes[i+18] < 100 {
                n += 1; xSum += x; ySum += y
            }
        }
    }
    return (n, n > 0 ? CGPoint(x: xSum/n, y: ySum/n) : nil)
}

@MainActor private func makeMarker(at url: URL) throws {
    let image = NSImage(size: .init(width: 128, height: 128), flipped: false) { rect in
        for i in 0..<4 {
            NSColor(srgbRed: i.isMultiple(of: 2) ? 1 : 0, green: i.isMultiple(of: 2) ? 0 : 1,
                    blue: i.isMultiple(of: 2) ? 0.85 : 0.16, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(x: CGFloat(i) * rect.width/4, y: 0, width: rect.width/4, height: rect.height)).fill()
        }
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        throw DesktopTrialStop("BLOCKED", "markerEncoding")
    }
    try png.write(to: url, options: .withoutOverwriting)
    _ = NSWorkspace.shared.setIcon(image, forFile: url.path, options: [])
}

@MainActor func qualifyDesktopItems(root: URL) async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS" else {
        throw DesktopTrialStop("BLOCKED", "requiresDisposableHostedLogin")
    }
    var receipt: [String: Any] = ["status": "BLOCKED", "sourceRevision": env["GITHUB_SHA"] ?? "",
        "installedHost": "NOT_RUN", "directPreferenceWrites": 0]
    var counts = [String: [Int]](), original: DesktopItemDisplay?, created: URL?, mayHaveChanged = false
    let settingsID = "com.apple.systempreferences"
    let hadSettings = !NSRunningApplication.runningApplications(withBundleIdentifier: settingsID).isEmpty
    let pointer = CGEvent(source: nil)?.location
    func click(_ point: CGPoint, verify: () -> Bool) throws {
        guard verify(), let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw DesktopTrialStop("UNKNOWN", "pointerTargetChanged")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    do {
        guard !hadSettings, AXIsProcessTrusted(), CGPreflightPostEventAccess(), pointer != nil,
              let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw DesktopTrialStop("BLOCKED", "cleanSettingsOrPermissionsUnavailable")
        }
        let display = try await fixtureDisplay()
        let owner = try JSONDecoder().decode(Owner.self, from: Data(contentsOf: root.appendingPathComponent("a.json")))
        guard let win = enroll(owner, name: "a")?.first else { throw DesktopTrialStop("BLOCKED", "ordinaryFixture") }
        let bounds = CGDisplayBounds(display.displayID)
        func number(_ point: CGPoint) -> Int {
            NSWindow.windowNumber(at: CGPoint(x: point.x, y: bounds.maxY-point.y), belowWindowWithWindowNumber: 0)
        }
        func expectMarker(_ visible: Bool, _ label: String) async throws -> CGPoint? {
            var streak = 0, center: CGPoint?
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(160))
                let sample = try await desktopMarkerPixels(display)
                counts[label, default: []].append(sample.count)
                streak = (visible ? sample.count >= 18 : sample.count == 0) ? streak+1 : 0
                center = sample.center
                if streak == 2 { return center }
            }
            throw DesktopTrialStop(label == "baselineVisible" ? "BLOCKED" : "FAIL", label)
        }
        func workingWindow() async throws -> CGPoint {
            // Only this fresh, dedicated Settings instance may be hidden by the fixture.
            let settings = NSRunningApplication.runningApplications(withBundleIdentifier: settingsID)
            if settings.count == 1 { _ = settings[0].hide() }
            guard try await takeFocus(win), let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, win.id) as? [[String: Any]],
                  let raw = rows.first?[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw) else { throw DesktopTrialStop("BLOCKED", "fixtureFocus") }
            let p = CGPoint(x: rect.midX, y: rect.midY)
            guard number(p) == Int(win.id) else { throw DesktopTrialStop("BLOCKED", "fixtureObscured") }
            return p
        }
        let read = await DesktopItemsSetting.shared.choose(nil)
        guard case let .confirmed(initial) = read else {
            receipt["adapterRead"] = String(describing: read)
            receipt["pane"] = settingsControlSample()
            throw DesktopTrialStop("BLOCKED", "nativeDesktopItemsCheckboxUnreadable")
        }
        original = initial; receipt["originalMode"] = initial.rawValue
        let initialPane = settingsControlSample()
        receipt["initialControls"] = initialPane["desktopControls"]
        let before = initialPane["otherOptions"] as? [String: String]
        receipt["otherOptionsBefore"] = before
        mayHaveChanged = initial != .always
        let baselineMode = await DesktopItemsSetting.shared.choose(.always)
        receipt["alwaysSelection"] = String(describing: baselineMode)
        guard baselineMode == .confirmed(.always) else {
            receipt["pane"] = settingsControlSample()
            throw DesktopTrialStop("UNKNOWN", "baselineModeUnconfirmed")
        }
        _ = try await workingWindow()
        _ = try await expectMarker(false, "absentBeforeFixture")
        let url = desktop.appendingPathComponent("Nearpane-Fixture-" + UUID().uuidString + ".png")
        try makeMarker(at: url); created = url
        guard let marker = try await expectMarker(true, "baselineVisible") else { throw DesktopTrialStop("BLOCKED", "markerLocation") }
        mayHaveChanged = true
        let hiddenMode = await DesktopItemsSetting.shared.choose(.onWallpaperClick)
        receipt["onClickSelection"] = String(describing: hiddenMode)
        guard hiddenMode == .confirmed(.onWallpaperClick) else {
            receipt["pane"] = settingsControlSample()
            throw DesktopTrialStop("UNKNOWN", "hideModeUnconfirmed")
        }
        let after = settingsControlSample()["otherOptions"] as? [String: String]
        receipt["otherOptionsAfter"] = after
        if before?["click-wallpaper-to-reveal-desktop"] != nil, after?["click-wallpaper-to-reveal-desktop"] != nil {
            guard before == after else { throw DesktopTrialStop("FAIL", "unrelatedSystemOptionChanged") }
            receipt["otherOptionsReadback"] = "PASS"
        } else { receipt["otherOptionsReadback"] = "UNKNOWN" }
        let target = try await workingWindow()
        try click(target) { number(target) == Int(win.id) }
        _ = try await expectMarker(false, "ordinaryWindowClickHidden")
        receipt["hiddenMarkerHit"] = desktopHitSample(marker, number: number(marker))
        guard WallpaperRevealMonitor.isBlankDesktop(at: marker, windowNumber: number(marker)) else {
            throw DesktopTrialStop("UNKNOWN", "hiddenMarkerMayBeOccluded")
        }
        let blank = [0.19, 0.37, 0.57].flatMap { x in [0.24, 0.72, 0.83].map { y in
            CGPoint(x: bounds.width*x, y: bounds.height*y) } }.first {
                hypot($0.x-marker.x, $0.y-marker.y) > 90 && WallpaperRevealMonitor.isBlankDesktop(at: $0, windowNumber: number($0))
            }
        guard let blank else { throw DesktopTrialStop("BLOCKED", "blankWallpaperNotIdentified") }
        try click(blank) { WallpaperRevealMonitor.isBlankDesktop(at: blank, windowNumber: number(blank)) }
        guard let visible = try await expectMarker(true, "blankWallpaperRevealed") else {
            throw DesktopTrialStop("UNKNOWN", "visibleMarkerLocation")
        }
        receipt["visibleMarkerHit"] = desktopHitSample(visible, number: number(visible))
        guard !WallpaperRevealMonitor.isBlankDesktop(at: visible, windowNumber: number(visible)) else {
            throw DesktopTrialStop("FAIL", "visibleIconClassifiedAsBlank")
        }
        receipt["visibleIconRejectedAsBlank"] = true
        let back = try await workingWindow()
        try click(back) { number(back) == Int(win.id) }
        _ = try await expectMarker(false, "returnedToApplicationHidden")
        receipt["status"] = "PASS"
    } catch let stop as DesktopTrialStop {
        receipt["status"] = stop.status; receipt["reason"] = stop.reason
    } catch {
        let detail = error as NSError
        receipt["status"] = detail.domain == NSCocoaErrorDomain && detail.code == CocoaError.fileWriteNoPermission.rawValue ? "BLOCKED" : "UNKNOWN"
        receipt["reason"] = detail.domain; receipt["code"] = detail.code
    }
    if let created {
        do { try FileManager.default.removeItem(at: created); receipt["fixtureRemoved"] = true }
        catch { receipt["fixtureRemoved"] = false; receipt["status"] = "UNKNOWN" }
    }
    if let original, mayHaveChanged {
        let cleanup = await DesktopItemsSetting.shared.choose(original)
        let restored = cleanup == .confirmed(original)
        receipt["restoreSelection"] = String(describing: cleanup)
        receipt["originalModeRestored"] = restored
        if !restored { receipt["status"] = "UNKNOWN" }
    }
    if !hadSettings, let app = NSRunningApplication.runningApplications(withBundleIdentifier: settingsID).first {
        _ = app.terminate()
    }
    if let pointer { CGWarpMouseCursorPosition(pointer) }
    receipt["markerSamples"] = counts
    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
        .write(to: root.appendingPathComponent("trial.json"), options: .atomic)
}
