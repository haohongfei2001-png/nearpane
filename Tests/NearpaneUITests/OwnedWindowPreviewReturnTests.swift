import AppKit
import NearpaneCore
import Observation
import os
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Testing
@testable import NearpaneUI

/// Opt-in WindowServer readback of two windows belonging to this process. No desktop filter or input events.
@MainActor struct OwnedWindowPreviewReturnTests {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private func rgb(_ image: CGImage) throws -> [UInt8] {
        let center = try #require(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let ctx = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Array(bytes.prefix(3))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEARPANE_OWNED_PREVIEW_EVIDENCE"] != nil))
    func twoRealWindowSurfacesKeepTheirPixelsWhileCaptureIsStopped() async throws {
        guard #available(macOS 14.4, *) else { Issue.record("Current-process window enumeration requires macOS 14.4"); return }
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NEARPANE_OWNED_PREVIEW_EVIDENCE"]))
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screen = try #require(NSScreen.main)
        var receipt: [String: Any] = ["status": "UNKNOWN", "scope": "current-process WindowServer surfaces and production card renderer",
            "installedHostNativeSwipe": "NOT_RUN", "keyboardOrMouseEvents": 0, "nativeSpaceWrites": 0]
        var panels = [Panel]()
        defer {
            for panel in panels { panel.orderOut(nil); panel.close() }
            let clean = panels.allSatisfy { !$0.isVisible } && front != nil && front == NSWorkspace.shared.frontmostApplication?.processIdentifier
            receipt["fixturesClosedAndFrontPreserved"] = clean
            if !clean { receipt["status"] = "FAIL"; Issue.record("Fixture cleanup or foreground continuity failed") }
            if let json = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted]) {
                try? json.write(to: directory.appendingPathComponent("owned-window.json"), options: .atomic)
            }
        }
        for (idx, color) in [NSColor.red, .blue].enumerated() {
            let panel = Panel(contentRect: CGRect(x: screen.visibleFrame.midX + CGFloat(idx * 84), y: screen.visibleFrame.midY,
                width: 80, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hasShadow = false
            panel.backgroundColor = color
            panel.isOpaque = true
            panels.append(panel)
            panel.orderBack(nil)
            panel.display()
        }
        let windows = try await SCShareableContent.currentProcess.windows
        let fixture = DesktopGalleryTargetTests()
        let sources = try panels.map { panel in
            try #require(windows.first { $0.windowID == panel.windowNumber && $0.owningApplication?.processID == getpid() })
        }
        let birth = try OrdinaryProcessImage.read(getpid()).launch
        let rows = sources.enumerated().map { index, source in
            let r = source.frame
            return fixture.window(number: source.windowID, pid: getpid(), birth: birth,
                frame: .init(x: r.minX, y: r.minY, width: r.width, height: r.height), index: index, id: String(source.windowID))
        }
        var inventory = fixture.sample(rows)
        inventory.scopes = [.init(id: "scope", displayID: "display", records: [.init(id: "A", isCurrent: true, ordinaryUUID: UUID())])]
        let targets = try rows.map { try #require(DesktopWindowTarget($0, in: inventory)) }
        let originals = targets.map { StagePictureOriginal($0.key, forCard: true) }
        let cache = PreviewPixelCache<DesktopWindowGallery.StillSlot, DesktopWindowGallery.Still>()
        let appearance = UUID(), gallery = DesktopWindowGallery(permitsWindow: { $0.pid == getpid() }, cache: cache, lifetime: { _ in appearance })
        var starts = 0
        func capture(_ index: Int, channel: Int, reusing previous: CGImage? = nil) async throws -> CGImage {
            let target = targets[index], pipe = try #require(await WindowFrameStream(window: sources[index], target: target))
            try await pipe.start()
            starts += 1
            let timeout = Task { try await Task.sleep(for: .seconds(4)); pipe.finishOutput() }
            var accepted: CGImage?
            for await event in pipe.updates {
                guard case let .frame(frame) = event, let image = frame.image(reusing: previous), let pixel = try? rgb(image),
                      pixel[channel] > 180, pixel[(channel + 1) % 3] < 80, pixel[(channel + 2) % 3] < 80 else { continue }
                accepted = image
                pipe.published(frame)
                break
            }
            timeout.cancel()
            await pipe.stop()
            let image = try #require(accepted)
            cache.store(.init(target: target, lifetime: appearance, capture: .init(image: image, logicalSize: pipe.logicalSize),
                time: ProcessInfo.processInfo.systemUptime), for: .current(target.key), cost: try #require(PreviewPixelBudget.charge(image)))
            return image
        }
        func read(_ i: Int) throws -> CGImage {
            try #require(DesktopWindowGallery.lastCardPixels(targets[i], in: cache, appearance: appearance,
                now: ProcessInfo.processInfo.systemUptime, allows: { _ in
                    panels[i].windowNumber == targets[i].key.number && targets[i].lastFrameAccess() == .allowed
                }, originalMatches: { _, _ in false }))
        }
        let red = try await capture(0, channel: 0)
        let oldCard = UUID(), newCard = UUID(), peerCard = UUID()
        gallery.setCard(targets[0].key, on: targets[0].display, owner: oldCard, visible: true)
        let mountInvalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = gallery.image(for: targets[0], permitted: true)
        } onChange: { mountInvalidated.withLock { $0 = true } }
        gallery.setCard(targets[1].key, on: targets[1].display, owner: peerCard, visible: true)
        gallery.setCard(targets[1].key, on: targets[1].display, owner: peerCard, visible: false)
        gallery.setCard(targets[0].key, on: targets[0].display, owner: oldCard, visible: true)
        receipt["currentCardInvalidatedByPeerMountOrRepeatedAppearance"] = mountInvalidated.withLock { $0 }
        try #require(!mountInvalidated.withLock { $0 })
        let redInvalidated = OSAllocatedUnfairLock(initialState: false)
        let observedRed = withObservationTracking { try? read(0) } onChange: { redInvalidated.withLock { $0 = true } }
        try #require(observedRed === red)
        let blue = try await capture(1, channel: 2)
        receipt["existingCardInvalidatedBySiblingFirstFrame"] = redInvalidated.withLock { $0 }
        try #require(!redInvalidated.withLock { $0 })
        receipt["sourceWindowIDs"] = sources.map(\.windowID)
        receipt["initialWindowServerRGB"] = [try rgb(red), try rgb(blue)]
        var partial = inventory
        let evidence = try #require(inventory.native)
        partial.windows = []
        partial.native = .init(population: evidence.population, accessibility: evidence.accessibility, spaces: evidence.spaces,
            rows: evidence.rows, windowLimitReached: true, beganUptime: evidence.beganUptime, endedUptime: evidence.endedUptime,
            stageManagerEnabled: evidence.stageManagerEnabled, catalogComplete: false)
        var held = CurrentDesktopWindows.DepartingPictures(snapshot: inventory,
            appearances: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, appearance) }), groups: [:])
        let sameHomes = held.retainAcrossCappedInventory(partial)
        try #require(sameHomes)
        let ticket = try #require(held.cappedAppearance)
        let countBeforePartial = starts
        let cappedPixels = targets.enumerated().map { index, target in
            DesktopWindowGallery.lastCardPixels(target, in: cache, appearance: ticket, now: ProcessInfo.processInfo.systemUptime,
                allows: { _ in panels[index].windowNumber == target.key.number && target.lastFrameAccess() == .allowed },
                originalMatches: { _, _ in originals[index]?.matches(target.key) == true })
        }
        receipt["controlledCappedInventory"] = "Injected incomplete metadata and display home; actual owned panel pixels and original AX window identity"
        receipt["captureStartsDuringCappedInventory"] = starts - countBeforePartial
        try #require(starts == countBeforePartial)
        if originals.allSatisfy({ $0 != nil }) {
            try #require(cappedPixels[0] === red && cappedPixels[1] === blue)
            receipt["controlledCappedOriginalAXReplay"] = "PASS"
            receipt["cappedInventoryRGB"] = try cappedPixels.compactMap { $0 }.map(rgb)
        } else {
            for i in originals.indices where originals[i] == nil { try #require(cappedPixels[i] == nil) }
            receipt["controlledCappedOriginalAXReplay"] = "BLOCKED"
            receipt["cappedBlocker"] = "The test runner could not retain both original AX windows"
        }
        receipt["surfaces"] = targets.enumerated().map { i, target -> [String: Any] in
            let row = WindowSurfaceRecord(number: target.key.number)
            return ["id": target.key.number, "sameOwnedWindow": panels[i].windowNumber == target.key.number,
                "hasRecord": row != nil, "ownerMatches": row?.pid == getpid(), "layer": row?.layer ?? -1,
                "allowsSharing": row?.allowsSharing == true, "drawn": row?.isDrawn == true,
                "appSharingType": panels[i].sharingType.rawValue, "frameMatches": row?.frame == target.frame]
        }
        let first = targets[0], startsBeforeHandoff = starts
        let cancelledCard = UUID()
        gallery.setViewport(first.key, on: first.display, owner: oldCard, visible: true)
        gallery.setCard(first.key, on: first.display, owner: cancelledCard, visible: true)
        gallery.setViewport(first.key, on: first.display, owner: cancelledCard, visible: false)
        gallery.setCard(first.key, on: first.display, owner: cancelledCard, visible: false)
        gallery.setViewport(first.key, on: first.display, owner: cancelledCard, visible: false)
        let retained = try read(0)
        try #require(gallery.priority(first) == 2 && !mountInvalidated.withLock { $0 } && retained === red)
        gallery.setCard(first.key, on: first.display, owner: newCard, visible: true)
        gallery.setViewport(first.key, on: first.display, owner: newCard, visible: true)
        gallery.setViewport(first.key, on: first.display, owner: oldCard, visible: false)
        gallery.setCard(first.key, on: first.display, owner: oldCard, visible: false)
        gallery.setViewport(first.key, on: first.display, owner: oldCard, visible: false)
        let handoffImage = try read(0)
        try #require(gallery.priority(first) == 2 && !mountInvalidated.withLock { $0 })
        try #require(handoffImage === red && starts == startsBeforeHandoff && !redInvalidated.withLock { $0 })
        receipt["overlappingCardHandoffRGB"] = try rgb(handoffImage)
        receipt["captureStartsDuringCardHandoff"] = starts - startsBeforeHandoff
        receipt["replacementRetainedMountAndViewport"] = true
        gallery.setCard(first.key, on: first.display, owner: newCard, visible: false)
        try #require(mountInvalidated.withLock { $0 })
        gallery.clear(display: targets[0].display, keepingCardFrames: true)
        let before = starts
        let returned = try read(0), peer = try read(1)
        let card = DesktopWindowCard(label: "Fixture A", icon: nil, image: returned, pictureSize: CGSize(width: 80, height: 60)).frame(width: 80)
        let drawn = try #require(ImageRenderer(content: card).cgImage)
        let drawnRGB = try rgb(drawn)
        try #require(returned === red && peer === blue && starts == before && drawnRGB[0] > 180 && drawnRGB[1] < 80)
        try NSBitmapImageRep(cgImage: drawn).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("returned-card.png"))
        let baseline = try await capture(0, channel: 0, reusing: returned)
        try #require(baseline === returned)
        receipt["unchangedCompositorBaselineReusedBitmap"] = true
        panels[0].backgroundColor = .green
        panels[0].display()
        let green = try await capture(0, channel: 1, reusing: baseline)
        let changed = try read(0), unchanged = try read(1)
        try #require(changed === green && unchanged === blue)
        let blueInvalidated = OSAllocatedUnfairLock(initialState: false)
        let observedBlue = withObservationTracking { try? read(1) } onChange: { blueInvalidated.withLock { $0 = true } }
        try #require(observedBlue === blue)
        cache.remove(.current(targets[0].key))
        receipt["existingCardInvalidatedBySiblingEviction"] = blueInvalidated.withLock { $0 }
        try #require(!blueInvalidated.withLock { $0 })
        receipt["ownerPID"] = getpid()
        receipt["ownerBirth"] = birth
        receipt["captureStartsDuringReturn"] = 0
        receipt["captureStartsTotal"] = starts
        receipt["returnedCardRGB"] = drawnRGB
        receipt["changedWindowRGB"] = try rgb(green)
        receipt["untouchedSiblingRGB"] = try rgb(blue)
        receipt["sameBitmapOnReturn"] = true
        receipt["status"] = "PASS"
    }
}
