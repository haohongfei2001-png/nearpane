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

private actor TestCaptureDirectory: CaptureLocationProviding {
    let url: URL
    private(set) var starts = 0
    private(set) var stops = 0
    init(_ url: URL) { self.url = url }
    func currentDirectory() async throws -> URL { url }
    func start(onChange: @escaping @Sendable () async -> Void) async throws { starts += 1 }
    func stop() async { stops += 1 }
}

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

    @Test func desktopReaderFailureDoesNotInterruptRealIsolatedVoiceAndTray() async throws {
        let root = fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Nearpane"), id = try await seedVoice(support)
        let expected = try await seedQueue(root)
        let domains = EmbeddedModules(support: support)
        let provider = NativeDesktopProvider(fixtureWindows: { nil }, anchors: { [] }) { _ in throw ReaderFailure.unavailable }
        let host = domains.makeHost(store: MemoryConfigurationStore(), provider: provider)
        await host.start(); await domains.voice.waitForTransition()
        await domains.tray.connect()
        let order = domains.tray.rows.map(\.id)
        await host.refreshDesktop()
        #expect(host.providerFailed && host.bus.desktop == nil && Set(order) == expected)
        #expect(await domains.voice.saveEdit(id, text: "隔离编辑"))
        host.setExperimentalSpaceObservation(true)
        await host.refreshDesktop()
        #expect(domains.voice.transcript.hasPrefix("隔离编辑") && domains.voice.control.state == .paused)
        #expect(domains.tray.connected && domains.tray.rows.map(\.id) == order && !domains.tray.mayAttach)
        #expect(host.registry.states[BuiltinCatalog.voice] == .resident && host.registry.states[BuiltinCatalog.screenshots] == .resident)
        host.stop(); await domains.finishStopping()
    }

    @Test func liveReaderChildCannotKeepIsolatedDomainWriterLocksAfterClose() async throws {
        let fm = FileManager.default, root = fixtureRoot(), support = root.appendingPathComponent("Nearpane")
        defer { try? fm.removeItem(at: root) }
        let recording = try await seedVoice(support)
        _ = try await seedQueue(root)
        let voiceURL = support.appendingPathComponent("Voice"), trayURL = root.appendingPathComponent("Riftlet")
        let voice = try SaytileStore(directory: voiceURL), tray = try ApplicationInstanceOwnership(root: trayURL)
        // Deliberately omit CLOEXEC on a third test-only descriptor. The transport must close it independently.
        let probe = root.appendingPathComponent("inheritance.lock")
        let fd = Darwin.open(probe.path, O_CREAT | O_RDWR, 0o600)
        try #require(fd >= 0)
        var ownerFD = fd
        defer { if ownerFD >= 0 { Darwin.close(ownerFD) } }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let executable = root.appendingPathComponent("reader")
        try "#!/bin/sh\necho ready > \"$0.ready\"\nexec /bin/sleep 12\n".write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let req = DesktopReadRequest(session: UUID(), revision: 1, parentPID: getpid(), fixtureWindows: [], anchors: [], experimentalSpaces: false)
        let child = Task { try await DesktopReaderProcess.read(executable: executable, request: req, timeout: 10) }
        defer { child.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let ready = root.appendingPathComponent("reader.ready")
        while !fm.fileExists(atPath: ready.path) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(fm.fileExists(atPath: ready.path))
        try await voice.close(); tray.close()
        Darwin.close(ownerFD); ownerFD = -1
        let next = Darwin.open(probe.path, O_RDWR | O_CLOEXEC)
        try #require(next >= 0)
        defer { Darwin.close(next) }
        try #require(flock(next, LOCK_EX | LOCK_NB) == 0)
        for _ in 0..<8 {
            let reopened = try SaytileStore(directory: voiceURL), connected = try ApplicationInstanceOwnership(root: trayURL)
            #expect(try await reopened.recording(id: recording)?.id == recording)
            try await reopened.close(); connected.close()
        }
        child.cancel()
        await #expect(throws: CancellationError.self) { try await child.value }
    }

    @Test func repeatedHostAndDomainShutdownReleaseFixtureDescriptorsAndBothLocks() async throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Nearpane")
        let voiceRoot = support.appendingPathComponent("Voice")
        let trayRoot = root.appendingPathComponent("Riftlet")
        _ = try await seedVoice(support)
        let ids = try await seedQueue(root)
        let domains = EmbeddedModules(support: support)
        let host = domains.makeHost(store: MemoryConfigurationStore())
        var initialOrder: [UUID]?
        func fixtureDescriptorCount() throws -> Int {
            var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap(Int32.init)
            return descriptors.filter { fd in
                fcntl(fd, F_GETPATH, &path) == 0 && String(decoding: path.prefix { $0 != 0 }, as: UTF8.self).hasPrefix(root.path + "/")
            }.count
        }
        for _ in 0..<32 {
            await host.start()
            await domains.voice.waitForTransition()
            await domains.tray.connect()
            let order = domains.tray.rows.map(\.id)
            if initialOrder == nil { initialOrder = order }
            #expect(Set(order) == ids && order == initialOrder)
            #expect(domains.voice.transcript == [firstLine, secondLine].joined(separator: "\n"))
            #expect(domains.voice.capture == .paused && !domains.tray.mayAttach && !domains.tray.collectionEnabled)
            #expect(try fixtureDescriptorCount() > 0)
            #expect(throws: LibraryError.busy) { try ExistingLibrary.open(trayRoot) }
            host.stop()
            await domains.finishStopping()
            #expect(!domains.tray.connected && !domains.voice.active && host.bus.moduleSnapshots.isEmpty)
            #expect(try fixtureDescriptorCount() == 0)
            let voice = try SaytileStore(directory: voiceRoot)
            try await voice.close()
            try ApplicationInstanceOwnership(root: trayRoot).close()
        }
        let diagnostics = try #require(JSONSerialization.jsonObject(with: host.diagnostics.export()) as? [[String:Any]])
        #expect(diagnostics.count <= host.diagnostics.capacity)
        #expect(diagnostics.allSatisfy { Set($0.keys).isSubset(of: ["code", "timestamp", "moduleID"]) })
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

    @Test func residentDisplayLossAndReturnRetainTheLiveStoreWatcherAndUnsentQueue() async throws {
        _ = NSApplication.shared
        let root = fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Nearpane"), recording = try await seedVoice(support)
        let ids = try await seedQueue(root)
        let directory = root.appendingPathComponent("test-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let watcher = TestCaptureDirectory(directory)
        let domains = EmbeddedModules(support: support)
        let host = domains.makeHost(store: MemoryConfigurationStore())
        await host.start(); await domains.voice.waitForTransition(); await domains.tray.connect()
        await domains.tray.collect(from: directory, provider: watcher)
        let main = EdgeWindowController(host: host, modules: domains)
        let panels = DisplayPanels(host: host, primary: main, domains: domains, present: { _ in })
        defer { panels.stop(); main.close(); host.stop() }

        let store = try await domains.voice.withPanelRead { $0 }
        let ticket = try await store.beginRecognition(recordingID: recording)
        let edited = "这条手记已由用户校对"
        try #require(await domains.voice.saveEdit(recording, text: edited))
        domains.voice.stageDraft(recording, text: draft)
        let epochs = host.bus.moduleSnapshots.mapValues(\.instanceID)
        let order = domains.tray.visibleIDs
        try #require(Set(order) == ids && epochs[BuiltinCatalog.voice] != nil && epochs[BuiltinCatalog.screenshots] != nil)
        try #require(await watcher.starts == 1)
        let previousStops = await watcher.stops
        let landscape = SurfaceRect(width: 1600, height: 900), portrait = SurfaceRect(x: -800, width: 800, height: 1280)
        let resident = ScreenGeometry(id: "resident", frame: landscape, visibleFrame: landscape)
        let side = ScreenGeometry(id: "side", frame: portrait, visibleFrame: portrait)
        var sideSettings = DisplaySettings()
        sideSettings.policy = .pinned
        host.setPlacement(edge: .right, displayID: resident.id)
        host.setDisplaySettings(sideSettings, id: side.id)
        panels.update(screens: [resident, side])
        #expect(host.panelContents[side.id] == .spacesOnly)

        func verifyDomains() async throws {
            #expect(host.bus.moduleSnapshots.mapValues(\.instanceID) == epochs)
            let current = try await domains.voice.withPanelRead { $0 }
            #expect(current === store && domains.voice.capture == .paused)
            #expect(await domains.voice.editText(recording) == draft)
            #expect(domains.voice.transcript == [edited, secondLine].joined(separator: "\n"))
            #expect(domains.tray.visibleIDs == order && domains.tray.collectionEnabled && !domains.tray.mayAttach)
            #expect(throws: LibraryError.busy) { try ExistingLibrary.open(root.appendingPathComponent("Riftlet")) }
            #expect(await watcher.starts == 1)
            #expect(await watcher.stops == previousStops)
        }
        panels.update(screens: [side])
        #expect(host.panelContents[resident.id] == nil && main.hasPlacement && panels.secondaryIDs.isEmpty)
        try await verifyDomains()
        // A recognition result that started on the disconnected display arrives after the manual edit.
        try #require(try await store.applyRecognition(ticket: ticket, text: "迟到的识别版本", isFinal: true))
        try await store.finishRecognition(ticket: ticket)
        await domains.voice.refresh()
        host.setSurfaceHidden(true)
        panels.update(screens: [side, resident])
        #expect(!main.hasPlacement && panels.secondaryIDs.isEmpty)
        try await verifyDomains()
        host.setSurfaceHidden(false)
        panels.update(screens: [side, resident])
        #expect(main.hasPlacement && panels.secondaryIDs == [side.id] && host.panelContents[side.id] == .spacesOnly)
        #expect(host.configuration.preferredDisplayID == resident.id && main.window?.isVisible == false)
        try await verifyDomains()
        host.stop(); await domains.finishStopping()
        #expect(await watcher.stops > previousStops)
        try ApplicationInstanceOwnership(root: root.appendingPathComponent("Riftlet")).close()
    }

    @Test func foldedAndExpandedPanelPreservesExistingDomainSessionAndQueue() async throws {
        _ = NSApplication.shared
        let root = fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Nearpane"), recording = try await seedVoice(support)
        let assets = try await seedQueue(root)
        let domains = EmbeddedModules(support: support), host = domains.makeHost(store: MemoryConfigurationStore())
        await host.start(); await domains.voice.waitForTransition(); await domains.tray.connect()
        let order = domains.tray.rows.map(\.id), originalStates = host.registry.states
        try #require(Set(order) == assets)
        let transcript = domains.voice.transcript, capture = domains.voice.capture
        domains.voice.stageDraft(recording, text: draft)
        let panel = EdgeWindowController(host: host, modules: domains)
        let bounds = SurfaceRect(x: -800, width: 800, height: 1280)
        let screen = ScreenGeometry(id: "portrait", frame: bounds, visibleFrame: bounds)
        panel.place(on: screen, primary: screen.id, content: .full)
        let initial = panel.requestedFrame
        var settings = DisplaySettings()
        settings.measures = [.panelWidth: .init(20), .panelHeight: .init(20)]
        host.setDisplaySettings(settings, id: screen.id)
        panel.place(on: screen, primary: screen.id, content: .full)
        panel.toggleTemporaryExpansion()
        panel.toggleTemporaryExpansion()
        host.setDisplaySettings(.init(), id: screen.id)
        panel.place(on: screen, primary: screen.id, content: .full)
        #expect(panel.requestedFrame == initial && !panel.temporarilyExpanded)
        #expect(domains.voice.active && domains.voice.capture == capture && domains.voice.transcript == transcript)
        #expect(await domains.voice.editText(recording) == draft)
        #expect(domains.tray.connected && domains.tray.rows.map(\.id) == order)
        #expect(host.registry.states == originalStates && panel.window?.isVisible == false)
        panel.close(); host.stop(); await domains.finishStopping()
    }
}
#endif
