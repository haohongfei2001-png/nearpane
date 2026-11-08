#if canImport(NearpaneVoice) && canImport(NearpaneTray)
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
import NearpaneCore
import SaytileKit
import RiftletCore
import RiftletCapture
@testable import NearpaneVoice
@testable import NearpaneTray
@testable import NearpaneUI

/// Shipping composition, existing-format libraries under a unique test root, zero device or target access.
@MainActor @Suite(.serialized)
struct IntegratedHostTests {
    private let firstLine = "今天先把第一条观察记下来。"
    private let secondLine = "同一段文字，修订后继续保留。"
    private let draft = "下次继续编辑的草稿"
    private func fixtureRoot() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(ProcessInfo.processInfo.environment["NEARPANE_TEST_DIRECTORY"] ?? ".build/test-data").appendingPathComponent("unified-" + UUID().uuidString, isDirectory: true)
    }
    private func seedVoice(_ support: URL) async throws -> UUID {
        let store = try SaytileStore(directory: support.appendingPathComponent("Voice"))
        var ids = [UUID]()
        for (index, text) in [firstLine, secondLine].enumerated() {
            let row = try await store.createRecording(createdAt: Date(timeIntervalSince1970: Double(index + 1)))
            let ticket = try await store.beginRecognition(recordingID: row.id)
            _ = try await store.applyRecognition(ticket: ticket, text: text, isFinal: true)
            try await store.finishRecording(id: row.id)
            try await store.finishRecognition(ticket: ticket)
            ids.append(row.id)
        }
        try await store.close()
        return ids[0]
    }
    private func seedQueue(_ root: URL) async throws -> Set<UUID> {
        let library = root.appendingPathComponent("Riftlet")
        let lock = try ApplicationInstanceOwnership(root: library)
        defer { lock.close() }
        let store = try QueueStore(databaseURL: library.appendingPathComponent("queue.sqlite"))
        let importer = PrivateAssetImporter(privateRoot: library, store: store)
        let output = library.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var ids = Set<UUID>()
        for (i, size) in [CGSize(width: 160, height: 80), .init(width: 68, height: 126), .init(width: 100, height: 100)].enumerated() {
            let bitmap = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let colors = [CGColor(red: 0.18, green: 0.48, blue: 0.65, alpha: 1), CGColor(red: 0.76, green: 0.4, blue: 0.25, alpha: 1),
                          CGColor(red: 0.24, green: 0.53, blue: 0.40, alpha: 1)]
            bitmap.setFillColor(colors[i]); bitmap.fill(CGRect(origin: .zero, size: size))
            bitmap.setFillColor(CGColor(gray: 0.94, alpha: 0.9))
            bitmap.fillEllipse(in: CGRect(x: size.width * 0.24, y: size.height * 0.32, width: 28, height: 28))
            let url = output.appendingPathComponent("fixture-\(i).png")
            let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(writer, try #require(bitmap.makeImage()), nil)
            try #require(CGImageDestinationFinalize(writer))
            ids.insert(try await importer.importBuiltInScreenshot(original: url, outputDirectory: output).id)
        }
        return ids
    }

    @Test func sharedHostKeepsDomainDataSeparateAndRestoresOnlyDurableState() async throws {
        let root = fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Nearpane"), id = try await seedVoice(support)
        let ids = try await seedQueue(root)
        let config = FileConfigurationStore(url: support.appendingPathComponent("host-configuration.json"))
        let domains = EmbeddedModules(support: support), host = domains.makeHost(store: config)
        await host.start(); await domains.voice.waitForTransition()
        #expect(host.registry.states[BuiltinCatalog.voice] == .resident && host.registry.states[BuiltinCatalog.screenshots] == .resident)
        #expect(!domains.tray.connected && !domains.tray.collectionEnabled && !domains.tray.mayAttach)
        #expect(domains.voice.transcript == firstLine + "\n" + secondLine)
        await domains.tray.connect()
        try #require(domains.tray.connected && domains.tray.captureEntry)
        let queue = domains.tray.rows.map(\.id)
        #expect(Set(queue) == ids)
        domains.tray.toggleMenu()
        #expect(domains.tray.expanded)
        #expect(await domains.voice.saveEdit(id, text: "已校对的原话。"))
        domains.voice.stageDraft(id, text: "下次")
        domains.voice.stageDraft(id, text: draft)
        #expect(domains.tray.rows.map(\.id) == queue && domains.tray.expanded)
        #expect(host.handle(.setEnabled(BuiltinCatalog.voice, false)) == .accepted)
        #expect(domains.tray.connected && domains.tray.expanded && domains.tray.rows.map(\.id) == queue)
        #expect(host.handle(.setEnabled(BuiltinCatalog.voice, true)) == .accepted)
        await domains.voice.waitForTransition()
        #expect(await domains.voice.editText(id) == draft)
        #expect(domains.voice.transcript == "已校对的原话。\n" + secondLine)
        host.setPlacement(edge: .left, displayID: "fixture-display")
        await host.selectFixture(.threeDisplays)
        let target = DesktopTarget(sessionID: UUID(), revision: 1, runtimeID: "fixture-only")
        #expect(host.bus.desktop == nil && !host.providerFailed)
        #expect(host.handle(.activateWindow(target)) == .rejected(.snapshotUnavailable))
        #expect(host.handle(.switchSpace(target)) == .rejected(.snapshotUnavailable))
        let projections = host.bus.moduleSnapshots.values.map(\.snapshot.message).joined()
        #expect(!projections.contains(secondLine) && !projections.contains("fixture-"))
        #expect(host.handle(.setEnabled(BuiltinCatalog.screenshots, false)) == .accepted)
        #expect(!domains.tray.connected && !domains.tray.expanded && domains.voice.rows.count == 2)
        host.setSurfaceHidden(true)
        host.stop(); await domains.finishStopping()
        let json = try String(contentsOf: config.url, encoding: .utf8)
        #expect(!json.contains(secondLine) && !json.contains(draft) && !json.contains(queue[0].uuidString))
        let reopened = EmbeddedModules(support: support), next = reopened.makeHost(store: config)
        await next.start(); await reopened.voice.waitForTransition()
        #expect(next.configuration.surfaceHidden && next.configuration.edge == .left && next.configuration.fixture == .threeDisplays)
        #expect(next.bus.desktop == nil && next.registry.states[BuiltinCatalog.screenshots] == .disabled)
        #expect(await reopened.voice.editText(id) == draft)
        #expect(reopened.voice.control.state == .paused && reopened.voice.transcript.hasPrefix("已校对的原话。"))
        #expect(await reopened.voice.discardDraft(id))
        #expect(await reopened.voice.editText(id) == "已校对的原话。")
        next.handle(.setEnabled(BuiltinCatalog.screenshots, true))
        #expect(!reopened.tray.connected)
        await reopened.tray.connect()
        #expect(reopened.tray.rows.map(\.id) == queue && !reopened.tray.mayAttach && !reopened.tray.collectionEnabled)
        next.stop(); await reopened.finishStopping()
    }

    @Test func standaloneVoiceTextAndDefaultsStayOutsideTheHostStore() async throws {
        let root = fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Nearpane")
        let standalone = root.appendingPathComponent("Saytile")
        let other = try SaytileStore(directory: standalone)
        let unrelated = try await other.createRecording()
        _ = try await other.saveEdit(recordingID: unrelated.id, text: "独立测试库专属文字")
        try await other.close()
        let preferences = standalone.appendingPathComponent("recognition-settings.json")
        let original = Data(#"{"cloudEnabled":true,"testFixture":true}"#.utf8)
        try original.write(to: preferences)
        let domains = EmbeddedModules(support: support), host = domains.makeHost(store: MemoryConfigurationStore())
        await host.start(); await domains.voice.waitForTransition()
        #expect(domains.voice.active && domains.voice.transcript.isEmpty && domains.voice.capture == .paused)
        host.stop(); await domains.finishStopping()
        let reopened = try SaytileStore(directory: standalone)
        #expect(try await reopened.recording(id: unrelated.id)?.text == "独立测试库专属文字")
        #expect(try Data(contentsOf: preferences) == original)
        try await reopened.close()
        let alias = root.appendingPathComponent("redirected-support")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: standalone)
        let redirected = EmbeddedModules(support: alias), failed = redirected.makeHost(store: MemoryConfigurationStore())
        await failed.start()
        #expect(failed.registry.states[BuiltinCatalog.voice] == .degraded)
        #expect(!FileManager.default.fileExists(atPath: standalone.appendingPathComponent("Voice").path))
        failed.stop(); await redirected.finishStopping()
    }

    @Test func failingVoiceStoreCanRetryWithoutTakingDownConnectedTray() async throws {
        let root = fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Nearpane")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let obstruction = support.appendingPathComponent("Voice")
        try Data("fixture obstruction".utf8).write(to: obstruction)
        let ids = try await seedQueue(root)
        let domains = EmbeddedModules(support: support), host = domains.makeHost(store: MemoryConfigurationStore())
        await host.start()
        #expect(host.registry.states[BuiltinCatalog.voice] == .degraded)
        await domains.tray.connect()
        #expect(domains.tray.connected && Set(domains.tray.rows.map(\.id)) == ids)
        host.handle(.setEnabled(BuiltinCatalog.voice, true))
        await domains.voice.waitForTransition()
        #expect(host.registry.states[BuiltinCatalog.voice] == .degraded)
        try FileManager.default.moveItem(at: obstruction, to: support.appendingPathComponent("preserved-fixture"))
        host.handle(.setEnabled(BuiltinCatalog.voice, true))
        await domains.voice.waitForTransition()
        #expect(host.registry.states[BuiltinCatalog.voice] == .resident && domains.voice.active)
        #expect(domains.tray.connected && Set(domains.tray.rows.map(\.id)) == ids)
        host.stop(); await domains.finishStopping()
    }

    @Test func realHiddenPanelCanMountBothDomainsAndReflowWithoutOrderingFront() async throws {
        _ = NSApplication.shared
        let root = fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Nearpane")
        _ = try await seedVoice(support); _ = try await seedQueue(root)
        let domains = EmbeddedModules(support: support), host = domains.makeHost(store: MemoryConfigurationStore())
        await host.start(); await domains.voice.waitForTransition(); await domains.tray.connect()
        try #require(domains.tray.rows.count == 3 && domains.voice.rows.count == 2)
        let controller = EdgeWindowController(host: host, modules: domains)
        let frame = SurfaceRect(width: 1920, height: 960)
        controller.place(screens: [.init(id: "fixture", frame: frame, visibleFrame: frame)])
        let window = try #require(controller.window), content = try #require(window.contentView)
        content.appearance = NSAppearance(named: .aqua)
        content.layoutSubtreeIfNeeded()
        #expect(window.frame.width == 240 && window.frame.height == 960 && !window.isVisible)
        let hosting = try #require(content.subviews.first)
        for state in ["collapsed", "expanded"] {
            if state == "expanded" { domains.tray.toggleMenu() }
            hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
            #expect(hosting.bounds.size == window.frame.size && !window.isVisible)
            #expect(domains.tray.expanded == (state == "expanded"))
            let export = ProcessInfo.processInfo.environment["NEARPANE_RENDER_FIXTURES"] == "1"
            if state == "collapsed" || export {
                // The view is attached to a never-shown panel, so no screen capture or desktop pixels are read.
                try await Task.sleep(for: .milliseconds(240))
                hosting.layoutSubtreeIfNeeded()
                let rect = hosting.bounds
                let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: rect))
                hosting.cacheDisplay(in: rect, to: rep)
                // In a hidden window the behind-window material has no desktop. Supply a documented
                // neutral backdrop for the transparent view pixels rather than capturing anything behind it.
                let source = try #require(rep.cgImage)
                let flat = try #require(CGContext(data: nil, width: source.width, height: source.height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                let pixels = CGRect(x: 0, y: 0, width: source.width, height: source.height)
                flat.setFillColor(CGColor(gray: 0.95, alpha: 1)); flat.fill(pixels)
                flat.draw(source, in: pixels)
                // No other content is expected near the center of the bottom 5/8.
                // The area must actually contain the unknown-state label, not a clipped empty view.
                let bytes = try #require(flat.data).assumingMemoryBound(to: UInt8.self)
                var ink = 0
                for y in (source.height * 65 / 100)..<(source.height * 72 / 100) {
                    for x in (source.width / 8)..<(source.width * 7 / 8) {
                        let pixel = bytes.advanced(by: y * flat.bytesPerRow + x * 4)
                        if max(pixel[0], max(pixel[1], pixel[2])) < 200 { ink += 1 }
                    }
                }
                #expect(ink > 60)
                guard export else { continue }
                let bitmap = NSBitmapImageRep(cgImage: try #require(flat.makeImage()))
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/verification/hidden")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("host-\(state).png"))
            }
        }
        #expect(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
        controller.close(); host.stop(); await domains.finishStopping()
    }
}
#endif
