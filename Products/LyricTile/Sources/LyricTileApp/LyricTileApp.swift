import AppKit
import Combine
import Darwin
import Foundation
import LyricPlayback
import LyricUI
import TileKit

@main
@MainActor
enum LyricTileEntry {
    private static var delegate: (any NSApplicationDelegate)?
    static func main() {
        let application = NSApplication.shared
        let delegate: any NSApplicationDelegate
        if LyricDiagnosticApplicationDelegate.requested { delegate = LyricDiagnosticApplicationDelegate() }
        else { delegate = LyricTileApplicationDelegate() }
        self.delegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class LyricTileApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = LyricAppModel()
    private var panelController: LyricPanelController!
    private var auxiliary: LyricAuxiliaryController!
    private var statusItem: NSStatusItem!
    private var subscriptions: Set<AnyCancellable> = []
    private var transitionTask: Task<Void, Never>?
    private var suspendedForHost = false
    private var terminating = false
    private var terminateReady = false
    private let nativeLoadCheck = CommandLine.arguments.contains("--smoke-test")
    private var nativeLoadFailed = false
    private var tileCoordinator: TileDesktopCoordinator!
    private var placementTask: Task<Void, Never>?
    private var updateController: LyricUpdateController?
    private var previousCoordinationSetting: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = LyricPanelController(model: model)
        if !nativeLoadCheck { panelController.setPlacementPermission(false) }
        tileCoordinator = TileDesktopCoordinator(id: "com.holdsnow.lyrictile", reservedHeight: Double(LyricPanelLayout.maximumHeight),
            windowIDs: { [weak self] in self?.panelController.windowIDs.compactMap { UInt32(exactly: $0) } ?? [] },
            permit: { [weak self] allowed in self?.panelController.setPlacementPermission(allowed) },
            place: { [weak self] frame, display in self?.panelController.placeHidden(slot: frame, displayUUID: display) },
            show: { [weak self] in self?.panelController.show() },
            status: { [weak self] message in if let message { self?.model.actionMessage = message } })
        panelController.visibilityIntentDidChange = { [weak self] _ in
            guard let self, !nativeLoadCheck, !terminating else { return }
            placementTask?.cancel()
            placementTask = Task { [weak self] in await self?.configurePlacement() }
        }
        panelController.placementDidChange = { [weak self] frame, display, explicit in
            guard let self, model.settings.coordinateTiles, model.ownsSession else { return }
            if explicit {
                let screen = LyricScreenIdentity.screens.first { $0.id == display }?.screen
                let top = (screen?.visibleFrame.maxY ?? frame.maxY) - frame.maxY
                placementTask?.cancel()
                placementTask = Task { [weak self] in await self?.tileCoordinator.requestPlacement(displayID: display, top: top) }
            } else { tileCoordinator.invalidateDisplayGeometry() }
        }
        if !nativeLoadCheck { updateController = LyricUpdateController() }
        auxiliary = LyricAuxiliaryController(model: model)
        auxiliary.anchorFrame = { [weak self] in self?.panelController.panel.frame }
        model.requestShowPanel = { [weak self] in self?.activate(userInitiated: true) }
        model.requestHidePanel = { [weak self] in self?.panelController.hide(userInitiated: true) }
        model.requestReposition = { [weak self] in self?.reposition() }
        model.requestUpdateCheck = { [weak self] in self?.checkForUpdates() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "LyricTile")
            button.image?.isTemplate = true
            button.toolTip = "LyricTile · 歌词，自然在旁。"
        }
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self; statusItem.menu = menu
        rebuildMenu(menu)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handoffRequested), name: LyricHandoff.request, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(ownerReleased), name: LyricHandoff.released, object: nil)
        model.$snapshot.sink { [weak self] snapshot in
            self?.statusItem.button?.toolTip = snapshot.selection?.recording.title.map { "LyricTile · \($0)" } ?? "LyricTile · 歌词，自然在旁。"
        }.store(in: &subscriptions)
        model.$settings.sink { [weak self] settings in
            guard let self else { return }
            let changed = previousCoordinationSetting != nil && previousCoordinationSetting != settings.coordinateTiles
            previousCoordinationSetting = settings.coordinateTiles
            if changed && model.ownsSession {
                placementTask?.cancel()
                placementTask = Task { [weak self] in await self?.configurePlacement() }
            }
        }.store(in: &subscriptions)
        if nativeLoadCheck { runNativeLoadCheck() }
        else if model.settings.completedWelcome { activate(userInitiated: false) }
        else { model.show(.welcome) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        nativeShutdownTrace("application-will-terminate")
        if nativeLoadCheck && nativeLoadFailed { Darwin.exit(EXIT_FAILURE) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if nativeLoadCheck { return false }
        activate(userInitiated: true); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        nativeShutdownTrace("termination-delegate-entered")
        if terminateReady { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        transitionTask?.cancel()
        placementTask?.cancel()
        panelController?.surrender(); auxiliary?.closeAll()
        Task { @MainActor [weak self] in
            guard let self else { return }
            nativeShutdownTrace("termination-drain-started")
            await tileCoordinator.stop()
            nativeShutdownTrace("tile-coordinator-stopped")
            await model.stop()
            nativeShutdownTrace("playback-model-stopped")
            LyricHandoff.announceRelease(from: .standalone)
            terminateReady = true
            nativeShutdownTrace("replying-to-termination")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if suspendedForHost {
            add(menu, "歌词正在 Nearpane 中显示", nil, enabled: false)
        } else if model.snapshot.state == .playing, model.snapshot.selection != nil {
            add(menu, panelController.wantsPresentation ? "隐藏歌词板" : "显示歌词板", #selector(togglePanel))
        } else {
            add(menu, model.snapshot.state == .paused ? "已暂停 · 播放后显示歌词" : "播放音乐时自动显示", nil, enabled: false)
            if model.snapshot.selection != nil, model.snapshot.capabilities.canPlay {
                add(menu, "继续播放", #selector(resumePlayback), enabled: model.ownsSession)
            }
        }
        if model.snapshot.requiresAuthorization {
            add(menu, "连接\(model.snapshot.player?.displayName ?? "播放器")", #selector(reconnect), enabled: model.ownsSession)
            add(menu, "允许访问播放器…", #selector(automationSettings))
        } else if let status = model.snapshot.statusMessage {
            add(menu, status, nil, enabled: false)
            add(menu, "重新连接", #selector(reconnect), enabled: model.ownsSession)
        }
        let source = NSMenuItem(title: "跟随的播放器", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu(); sourceMenu.autoenablesItems = false
        let automatic = add(sourceMenu, "自动", #selector(selectPlayer(_:)))
        automatic.representedObject = ""; automatic.state = model.settings.player == nil ? .on : .off
        for player in PlayerID.allCases {
            let item = add(sourceMenu, player.displayName, #selector(selectPlayer(_:)))
            item.representedObject = player.rawValue; item.state = model.settings.player == player ? .on : .off
        }
        source.submenu = sourceMenu; source.isEnabled = !suspendedForHost; menu.addItem(source)
        if model.snapshot.selection != nil {
            add(menu, "为当前歌曲导入歌词…", #selector(importLyrics), enabled: model.ownsSession)
            add(menu, "选择歌词版本…", #selector(chooseLyrics), enabled: model.ownsSession)
        }
        if model.document != nil { add(menu, "完整歌词", #selector(fullLyrics)) }
        menu.addItem(.separator())
        add(menu, "设置…", #selector(settings), key: ",")
        add(menu, "检查更新…", #selector(update))
        add(menu, "关于 LyricTile", #selector(about))
        menu.addItem(.separator())
        add(menu, "退出 LyricTile", #selector(quit), key: "q")
    }
    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.isEnabled = enabled; menu.addItem(item); return item
    }
    private func activate(userInitiated: Bool) {
        guard !terminating else { return }
        guard model.settings.completedWelcome else { model.show(.welcome); return }
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var acquired = await model.start()
            if !acquired && userInitiated {
                LyricHandoff.requestRelease(of: .host)
                for _ in 0..<40 where !acquired {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    acquired = await model.start()
                }
            }
            guard !Task.isCancelled, acquired else {
                statusItem.button?.toolTip = model.ownershipMessage ?? "歌词会话暂不可用"
                return
            }
            suspendedForHost = false
            panelController.resumePresentation()
            await configurePlacement()
            guard !Task.isCancelled, model.ownsSession, !terminating else { return }
            panelController.show(userInitiated: userInitiated)
        }
    }
    @objc private func handoffRequested(_ notification: Notification) {
        guard let requestID = LyricHandoff.requestID(from: notification, targeting: .standalone), model.ownsSession, !terminating else { return }
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ids = panelController.windowIDs
            panelController.surrender(); auxiliary.closeAll()
            guard await LyricHandoff.waitUntilWindowsWithdrawn(ids) else {
                LyricHandoff.acknowledge(requestID, succeeded: false)
                guard !Task.isCancelled, !terminating else { return }
                panelController.resumePresentation()
                panelController.show()
                return
            }
            guard !Task.isCancelled, !terminating else {
                LyricHandoff.acknowledge(requestID, succeeded: false)
                return
            }
            guard await tileCoordinator.stop() else {
                LyricHandoff.acknowledge(requestID, succeeded: false)
                model.actionMessage = "旧桌面占位尚未释放，歌词会话交接仍在等待。"
                return
            }
            guard !Task.isCancelled, !terminating else {
                LyricHandoff.acknowledge(requestID, succeeded: false)
                return
            }
            await model.stop()
            guard !Task.isCancelled, !terminating else { return }
            suspendedForHost = true
            LyricHandoff.acknowledge(requestID, succeeded: true)
        }
    }
    @objc private func ownerReleased(_ notification: Notification) {
        guard notification.userInfo?["role"] as? String == LyricHandoff.Role.host.rawValue,
              suspendedForHost, !terminating else { return }
        activate(userInitiated: false)
    }
    @objc private func togglePanel() {
        if panelController.wantsPresentation { panelController.hide(userInitiated: true) }
        else { activate(userInitiated: true) }
    }
    @objc private func selectPlayer(_ sender: NSMenuItem) {
        model.selectPlayer((sender.representedObject as? String).flatMap(PlayerID.init(rawValue:)))
    }
    @objc private func resumePlayback() { model.perform(.play) }
    @objc private func reconnect() { model.reconnect() }
    @objc private func automationSettings() { model.openAutomationSettings() }
    @objc private func importLyrics() { model.importLyrics() }
    @objc private func chooseLyrics() { model.show(.candidates) }
    @objc private func settings() { model.show(.settings) }
    @objc private func fullLyrics() { model.show(.fullLyrics) }
    @objc private func update() { checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "LyricTile", .credits: NSAttributedString(string: "HOLDSNOW · 歌词，自然在旁。")])
    }
    private func checkForUpdates() {
        if let message = updateController?.checkForUpdates() {
            model.actionMessage = message; model.show(.settings)
        }
    }
    private func configurePlacement() async {
        guard model.ownsSession, !terminating, !Task.isCancelled else { return }
        panelController.usesCoordinatedPlacement = model.settings.coordinateTiles
        guard panelController.wantsPresentation else {
            // Idle is absent from both the desktop and the shared tile column.
            // stop() retains TileKit's withdrawal/readback barrier before removal.
            await tileCoordinator.stop()
            return
        }
        if model.settings.coordinateTiles {
            await tileCoordinator.start(preferredDisplayID: model.settings.preferredDisplayUUID)
        } else {
            guard await tileCoordinator.stop() else { return }
            guard model.ownsSession, !terminating, !Task.isCancelled, !model.settings.coordinateTiles,
                  panelController.wantsPresentation else { return }
            panelController.restorePosition(reset: false)
            panelController.setPlacementPermission(true)
            panelController.show()
        }
    }
    private func reposition() {
        if model.settings.coordinateTiles && model.ownsSession {
            placementTask?.cancel()
            placementTask = Task { [weak self] in
                guard let self else { return }
                await tileCoordinator.requestPlacement(displayID: model.settings.preferredDisplayUUID, top: 16)
            }
        } else { panelController.restorePosition(reset: true) }
    }
    private func runNativeLoadCheck() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Allow initial production subscriptions to settle. No PlaybackController.start,
            // repository lookup, fabricated recording or permission request.
            try? await Task.sleep(for: .milliseconds(150))
            panelController.show(userInitiated: true)
            panelController.panel.contentView?.layoutSubtreeIfNeeded()
            panelController.panel.contentView?.displayIfNeeded()
            try? await Task.sleep(for: .seconds(2))
            let panel = panelController.panel
            let screenshotIndex = CommandLine.arguments.firstIndex(of: "--smoke-screenshot")
            let screenshotURL = screenshotIndex.flatMap { index in
                CommandLine.arguments.indices.contains(index + 1) ? URL(fileURLWithPath: CommandLine.arguments[index + 1]) : nil
            }
            var report: [String: Any] = ["check": "native-ui-load",
                                         "width": panel.frame.width, "height": panel.frame.height,
                                         "realPlayerTest": false, "networkStarted": false,
                                         "screenshotRequested": screenshotIndex != nil]
            let panelPassed = !panel.isVisible && !panelController.wantsPresentation
                && panel.contentView?.window === panel
                && panel.frame.width >= 176 && panel.frame.width <= 224
                && panel.frame.height == LyricPanelLayout.compactHeight
                && model.snapshot.selection == nil && !model.ownsSession
            report["idlePanelHidden"] = panelPassed
            // No screenshot of an intentionally absent panel. Capture actual settings
            // and welcome windows below; test-authored lyric renderings live in Tests.
            report["panelScreenshotSaved"] = false
            var auxiliaryPassed = true
            for page in [LyricAuxiliaryPage.welcome, .settings] {
                let observation = await captureNativeAuxiliaryPage(page, in: screenshotURL?.deletingLastPathComponent())
                report[page.rawValue] = observation
                auxiliaryPassed = auxiliaryPassed && (observation["passed"] as? Bool == true)
            }
            auxiliary.closeAll()
            let passed = panelPassed && auxiliaryPassed && model.snapshot.selection == nil && !model.ownsSession
            nativeLoadFailed = !passed
            report["passed"] = passed
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
            nativeShutdownTrace("smoke-surface-checked")
            // NSApplication's terminateLater machinery can nest the run loop. Leave the
            // current MainActor task first, so the delegate's asynchronous drain can run.
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
    }
    private func captureNativeAuxiliaryPage(_ page: LyricAuxiliaryPage, in directory: URL?) async -> [String: Any] {
        // Exercise the same production presentation subscription used by the menu and
        // first launch. No button is clicked and no permission or media action is invoked.
        model.show(page)
        try? await Task.sleep(for: .milliseconds(300))
        let window = NSApp.windows.first { $0 !== panelController.panel && $0.title == page.title }
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.contentView?.displayIfNeeded()
        let visible = window?.isVisible == true
        let mounted = window.map { $0.contentView?.window === $0 } ?? false
        let bounds = window?.contentView?.bounds ?? .zero
        var screenshotPassed = directory == nil
        var observation: [String: Any] = ["exists": window != nil, "visible": visible,
                                           "contentMounted": mounted,
                                           "width": bounds.width, "height": bounds.height]
        if let window, let directory, visible, mounted {
            do {
                try LyricNativeSmoke.capture(window: window, to: directory.appendingPathComponent("native-\(page.rawValue).png"))
                screenshotPassed = true
            } catch { observation["screenshotError"] = error.localizedDescription }
        }
        observation["screenshotSaved"] = directory != nil && screenshotPassed
        observation["passed"] = window != nil && visible && mounted && bounds.width > 0 && bounds.height > 0 && screenshotPassed
        auxiliary.closeAll()
        return observation
    }
    private func nativeShutdownTrace(_ stage: String) {
        guard nativeLoadCheck else { return }
        FileHandle.standardError.write(Data("LyricTile native smoke: \(stage)\n".utf8))
    }
}
