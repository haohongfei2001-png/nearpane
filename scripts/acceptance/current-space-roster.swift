import AppKit
import CReadOnlySpaces
import NearpaneCore
@preconcurrency import ScreenCaptureKit
import SwiftUI
@testable import NearpaneUI

private let folder = Bundle.main.bundleURL.deletingLastPathComponent()
private let swatches = [(26,137,82), (50,74,173), (207,116,31), (169,54,86)]
private struct OwnerReport: Codable {
    var pid: Int32
    var windows: [String: UInt32]
    var changed: Double
    var accessibility: [String: [String]]
    var frameSizes: [String: [Double]]
    var orderedOut: Bool
}
private struct TrialError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
private final class MarkedContent: NSView {
    let swatch: NSColor
    init(swatch: NSColor) { self.swatch = swatch; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        swatch.setFill(); bounds.fill()
        NSColor.cyan.setFill()
        for x in [8, Int(bounds.width) - 16] {
            for y in [8, Int(bounds.height) - 16] { NSRect(x: x, y: y, width: 8, height: 8).fill() }
        }
        for k in 0..<48 {
            (k.isMultiple(of: 2) ? NSColor.white : NSColor.black).setFill()
            NSRect(x: 24 + k, y: 12, width: 1, height: 10).fill()
        }
    }
}

private final class RosterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor enum RosterTrial {
#if TARGET_WINDOWS
    static func owner() {
        let app = NSApplication.shared
        let board = Bundle.main.bundleIdentifier == "net.example.nearpane-window-board"
        guard board || Bundle.main.bundleIdentifier == "net.example.nearpane-window-selection",
              app.activationPolicy() == .regular, let screen = NSScreen.screens.first else { exit(2) }
        NSWindow.allowsAutomaticWindowTabbing = false
        let name = board ? "board" : "notes"
        let sticky = CommandLine.arguments.contains("--public-visible")
        let mixed = CommandLine.arguments.contains("--mixed-roles")
        var windows = [Int:NSWindow](), added = false, removed = false, hidden = false, shownAgain = false
        var changed = ProcessInfo.processInfo.systemUptime
        func make(_ i: Int) {
            let sizes = [CGSize(width: 520, height: 175), CGSize(width: 230, height: 340),
                         CGSize(width: 300, height: 210), CGSize(width: 420, height: 230)]
            let rect = NSRect(origin: CGPoint(x: screen.visibleFrame.midX - 180 + CGFloat(i*9),
                                              y: screen.visibleFrame.midY - 150 + CGFloat(i*8)), size: sizes[i])
            let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
            let w: NSWindow
            if sticky || (mixed && i == 1) {
                var panelStyle = style.union(.nonactivatingPanel)
                if mixed { panelStyle.insert(.utilityWindow) }
                let panel = RosterPanel(contentRect:rect,styleMask:panelStyle,backing:.buffered,defer:true)
                panel.hidesOnDeactivate = false; w = panel
                w.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.canJoinAllApplications]
            } else {
                w = NSWindow(contentRect:rect,styleMask:style,backing:.buffered,defer:true,screen:screen)
                if mixed || CommandLine.arguments.contains("--all-spaces-documents") {
                    w.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
                }
            }
            w.level = .normal; w.isReleasedWhenClosed = false
            w.tabbingMode = .disallowed; w.setFrame(rect,display:false)
            w.title = ["旅行手记", "阅读笔记", "设计草图", "色彩样本"][i]
            let (r,g,b) = swatches[i]
            let content = MarkedContent(swatch: NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1))
            let label = NSTextField(labelWithString:w.title)
            label.font = .systemFont(ofSize:21,weight:.semibold); label.textColor = .white
            label.frame = NSRect(x:20,y:42,width:192,height:32); content.addSubview(label); w.contentView = content
            w.orderFrontRegardless(); windows[i] = w
            changed = ProcessInfo.processInfo.systemUptime
        }
        func write() {
            let report = OwnerReport(pid:getpid(), windows: Dictionary(uniqueKeysWithValues:windows.map { (String($0.key),UInt32($0.value.windowNumber)) }), changed:changed,
                                     accessibility: Dictionary(uniqueKeysWithValues: windows.map {
                                         (String($0.key), [$0.value.accessibilityRole()?.rawValue ?? "", $0.value.accessibilitySubrole()?.rawValue ?? ""])
                                     }),
                                     frameSizes: Dictionary(uniqueKeysWithValues:windows.map { (String($0.key), [$0.value.frame.width, $0.value.frame.height]) }),
                                     orderedOut: hidden && windows[2]?.isVisible == false)
            try? JSONEncoder().encode(report).write(to:folder.appendingPathComponent(name+".json"),options:.atomic)
        }
        let start = ContinuousClock.now
        DispatchQueue.main.async { for i in (board ? [2] : [0,1]) { make(i) }; write() }
        let timer = Timer(timeInterval:0.025,repeats:true) { _ in MainActor.assumeIsolated {
            if FileManager.default.fileExists(atPath:folder.appendingPathComponent("finish-roster").path) || ContinuousClock.now - start > .seconds(30) {
                for w in windows.values { w.close() }; app.terminate(nil); return
            }
            if board && !added && FileManager.default.fileExists(atPath:folder.appendingPathComponent("add-window").path) {
                added = true; make(3); write()
            }
            if !board && !removed && FileManager.default.fileExists(atPath:folder.appendingPathComponent("close-window").path) {
                removed = true; windows.removeValue(forKey:1)?.close(); changed = ProcessInfo.processInfo.systemUptime; write()
            }
            if board && !hidden && FileManager.default.fileExists(atPath:folder.appendingPathComponent("order-out").path) {
                hidden = true; windows[2]?.orderOut(nil); changed = ProcessInfo.processInfo.systemUptime; write()
            }
            if board && hidden && !shownAgain && FileManager.default.fileExists(atPath:folder.appendingPathComponent("order-in").path) {
                shownAgain = true; windows[2]?.orderFrontRegardless(); changed = ProcessInfo.processInfo.systemUptime; write()
            }
        }}
        RunLoop.main.add(timer,forMode:.common); app.run()
    }
#else
    static func run() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var result = [String:Any](), owners = [Process]()
        verification: do {
            guard let original, WindowContentPreview.sessionAvailable(), let screen = NSScreen.screens.first,
                  NSScreen.screens.count == 1, let d = SystemScreens.geometry().first, CGPreflightScreenCaptureAccess(),
                  let read = NativeDesktopProvider.packagedReader(overview:true) else { throw TrialError("窗口或现有取图权限不可用") }
            let sticky = CommandLine.arguments.contains("--public-visible")
            let coldBackground = CommandLine.arguments.contains("--cold-background")
            let mixed = CommandLine.arguments.contains("--mixed-roles")
            let allSpacesDocuments = CommandLine.arguments.contains("--all-spaces-documents")
            result["mixedRoles"] = mixed
            result["allSpacesDocuments"] = allSpacesDocuments
            result["publicVisibleFixture"] = sticky
            result["coldBackgroundFixture"] = coldBackground
            for (bundle,exe,id) in [("Design Notes.app","Notes","net.example.nearpane-window-selection"),("Sketch Board.app","Board","net.example.nearpane-window-board")] {
                let url=folder.appendingPathComponent(bundle)
                guard Bundle(url:url)?.bundleIdentifier == id else { throw TrialError("测试包身份不符") }
                let p=Process(); p.executableURL=url.appendingPathComponent("Contents/MacOS/"+exe)
                p.arguments = ["--roster"] + (sticky ? ["--public-visible"] : []) + (allSpacesDocuments ? ["--all-spaces-documents"] : []) + (mixed ? ["--mixed-roles"] : [])
                try p.run(); owners.append(p)
            }
            func report(_ name: String) -> OwnerReport? {
                (try? Data(contentsOf:folder.appendingPathComponent(name+".json"))).flatMap { try? JSONDecoder().decode(OwnerReport.self,from:$0) }
            }
            var focusDeparture = false
            func wait(_ seconds: Double, _ predicate: () -> Bool) async -> Bool {
                let end=ProcessInfo.processInfo.systemUptime+seconds
                repeat {
                    if predicate() { return true }
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier != original { focusDeparture = true; return false }
                    try? await Task.sleep(for:.milliseconds(15))
                } while ProcessInfo.processInfo.systemUptime < end
                return predicate()
            }
            guard await wait(6,{report("notes")?.pid == owners[0].processIdentifier && report("board")?.pid == owners[1].processIdentifier}) else {
                result["focusDeparture"] = focusDeparture
                throw TrialError(focusDeparture ? "测试窗口启动时出现前台变化" : "未在时限内同时读到两个测试窗口所属者")
            }
            if coldBackground {
                try Data().write(to:folder.appendingPathComponent("order-out"),options:.atomic)
                guard await wait(2,{report("board")?.orderedOut == true}) else { throw TrialError("窗口所属应用未确认进入后台") }
            }
            let pids=Set(owners.map(\.processIdentifier))
            let previews=WindowContentPreview(readOverview:{ request in
                // Exercise the sealed product reader, then restrict the acceptance view to the owned apps.
                var sample = try await read(request)
                sample.windows.removeAll { !pids.contains($0.metadata?.pid ?? 0) }
                return sample
            },permitsGalleryWindow:{pids.contains($0.pid)})
            let pointer=WorkspacePointerRegistry(), display=SurfaceDisplay()
            pointer.windowPreviews=previews; display.id=d.id; display.pointer=pointer; display.interactionVisible=true
            let host=HostSession(store:MemoryConfigurationStore(),includeSampleModules:false)
            await host.start(); defer { host.stop() }
            let size=NSSize(width:206,height:540)
            let view=NSHostingView(rootView:DesktopSurface(host:host,displayID:d.id,enabled:true,display:display)
                .frame(width:size.width,height:size.height).background(Color(nsColor:.windowBackgroundColor)))
            let panel=RosterPanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:true)
            panel.isOpaque=true; panel.backgroundColor = .windowBackgroundColor; panel.isReleasedWhenClosed=false
            panel.hidesOnDeactivate=false; panel.ignoresMouseEvents=true; panel.contentView=view
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.canJoinAllApplications]
            panel.setFrameOrigin(.init(x:screen.visibleFrame.minX+9,y:screen.visibleFrame.minY+12)); panel.orderBack(nil)
            defer { previews.setVisible(false,on:d.id); panel.orderOut(nil); panel.close() }
            let start=ProcessInfo.processInfo.systemUptime
            func milliseconds(_ since: Double) -> Int { Int((ProcessInfo.processInfo.systemUptime-since)*1000) }
            previews.setVisible(true,on:d.id)
            func members() -> [WindowObservation] {
                previews.currentDesktop?.snapshot?.currentDesktopWindows(on:d.id,now:.now,uptime:ProcessInfo.processInfo.systemUptime) ?? []
            }
            func expected() -> Set<UInt32> {
                var ids = Set(report("notes")?.windows.values.map { $0 } ?? [])
                if let board = report("board") {
                    for (slot, number) in board.windows where !(slot == "2" && board.orderedOut) {
                        ids.insert(number)
                    }
                }
                return ids
            }
            func complete(_ count: Int) -> Bool {
                let rows = members()
                let ids = Set(rows.compactMap{$0.metadata?.number})
                return rows.count == count && ids.count == count && ids == expected()
            }
            func sourceCount() -> Int {
                guard let sample=previews.currentDesktop?.snapshot else {return 0}
                return members().compactMap { DesktopWindowTarget($0,in:sample) }.filter {previews.gallery.image(for:$0,permitted:true) != nil}.count
            }
            func ownerWitness() -> [[String:Any]] {
                let publicIDs = Set((NSWindow.windowNumbers(options: .allApplications) ?? []).map(\.uint32Value))
                let inventory = NPReadOnlySpacesOpen() == 1 ? NPReadInventory() as? [[String:Any]] : nil
                let current = Set((inventory ?? []).compactMap { ($0["Current Space"] as? [String:Any])?["id64"] as? UInt64 })
                return [report("notes"),report("board")].compactMap { $0 }.flatMap { owner in
                    owner.windows.sorted { $0.key < $1.key }.map { slot, number in
                        let cg = (CGWindowListCopyWindowInfo(.optionIncludingWindow,number) as? [[String:Any]])?.first
                        let ids = NPReadWindowSpaces(number) as? [UInt64] ?? []
                        return ["slot":slot, "current":!current.isDisjoint(with:ids), "memberships":ids.count,
                                "publicVisible":publicIDs.contains(number), "onscreen":cg?[kCGWindowIsOnscreen as String] as? Bool ?? false,
                                "alpha":cg?[kCGWindowAlpha as String] as? Double ?? -1, "layer":cg?[kCGWindowLayer as String] as? Int ?? -100,
                                "listed":members().contains { $0.metadata?.number == number }] as [String:Any]
                    }
                }
            }
            if coldBackground {
                guard await wait(4, { complete(2) && sourceCount() == 2 }),
                      let board = report("board"), board.orderedOut, let originalNumber = board.windows["2"] else {
                    result["windowEvidence"] = ownerWitness()
                    throw TrialError("启动时已收起的测试窗口仍在列表中，或另两扇可见窗口的画面不全")
                }
                result["coldOrderedOutExcluded"] = true
                try Data().write(to: folder.appendingPathComponent("order-in"), options: .atomic)
                guard await wait(4, {
                    guard let board = report("board") else { return false }
                    return !board.orderedOut && board.windows["2"] == originalNumber && complete(3)
                }) else { throw TrialError("原测试窗口重新显示后未恢复到列表") }
                result["orderedInOriginalMember"] = true
            }
            if mixed {
                guard let notes = report("notes"), let board = report("board"),
                      let first = notes.windows["0"], let second = board.windows["2"], let panelID = notes.windows["1"],
                      Set([first, second, panelID]).count == 3 else { throw TrialError("合成窗口或所属者身份不完整") }
                let documents: Set<UInt32> = [first, second]
                let listSettled = await wait(5, {
                    guard let snap = previews.currentDesktop?.snapshot, snap.native?.spaces == .observed else { return false }
                    return members().count == 2 && Set(members().compactMap { $0.metadata?.number }) == documents && sourceCount() == 2
                })
                result["windowEvidence"] = ownerWitness()
                result["listSettled"] = listSettled
                result["readerAX"] = previews.currentDesktop?.snapshot?.native?.accessibility.rawValue ?? "noSample"
                result["readerSpaces"] = previews.currentDesktop?.snapshot?.native?.spaces.rawValue ?? "noSample"
                result["observerAX"] = AXIsProcessTrusted()
                var allProved = true, rows = [[String: Any]]()
                let here = Set((NSWindow.windowNumbers(options: .allApplications) ?? []).map(\.uint32Value))
                for owner in [notes, board] {
                    let app = AXUIElementCreateApplication(owner.pid)
                    AXUIElementSetMessagingTimeout(app, 0.3)
                    func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
                        var out: CFTypeRef?
                        return AXUIElementCopyAttributeValue(element, key as CFString, &out) == .success ? out : nil
                    }
                    let elements = AXIsProcessTrusted() ? value(app, kAXWindowsAttribute) as? [AXUIElement] : nil
                    for (slot, id) in owner.windows.sorted(by: { $0.key < $1.key }) {
                        let hits = (elements ?? []).filter { NPReadAXWindowNumber($0) == id }
                        var role: String?, subrole: String?, axOwner: pid_t = -1
                        if hits.count == 1, let w = hits.first {
                            AXUIElementGetPid(w, &axOwner)
                            role = value(w, kAXRoleAttribute) as? String
                            subrole = value(w, kAXSubroleAttribute) as? String
                        }
                        let ordinary = documents.contains(id)
                        let cg = WindowSurfaceRecord(number: id)
                        let presented = cg?.pid == owner.pid && cg?.layer == 0 && cg?.isOnscreen == true && cg?.isDrawn == true && here.contains(id)
                        let reported = owner.accessibility[slot] ?? []
                        let sameRole = role == kAXWindowRole && subrole != nil && reported == [role ?? "", subrole ?? ""]
                        let classified = ordinary ? subrole == kAXStandardWindowSubrole :
                            [kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole, kAXDialogSubrole].contains(subrole ?? "")
                        let listed = members().contains { $0.metadata?.pid == owner.pid && $0.metadata?.number == id }
                        let proved = presented && axOwner == owner.pid && sameRole && classified && listed == ordinary
                        allProved = allProved && proved
                        rows.append(["slot": slot, "pid": owner.pid, "number": id, "ownerAX": reported, "axMatches": hits.count,
                                     "externalAX": [role ?? "", subrole ?? ""], "axOwnerMatched": axOwner == owner.pid,
                                     "presented": presented, "listed": listed, "proved": proved])
                    }
                }
                result["perWindow"] = rows
                guard !focusDeparture, NSWorkspace.shared.frontmostApplication?.processIdentifier == original,
                      #available(macOS 14.4, *), let own = try await SCShareableContent.currentProcess.windows.first(where: {
                          $0.windowID == panel.windowNumber && $0.owningApplication?.processID == getpid()
                      }) else { throw TrialError("侧栏取证前焦点或窗口身份已变") }
                let cfg = SCStreamConfiguration()
                cfg.width = 412; cfg.height = 1080; cfg.showsCursor = false; cfg.ignoreShadowsSingleWindow = true; cfg.includeChildWindows = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: .init(desktopIndependentWindow: own), configuration: cfg)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent("mixed-window-sidebar.png"), options: .atomic)
                let counts = colorCounts(image)
                result["colorPixels"] = counts
                guard listSettled, rows.count == 3, allProved, counts.count == 4, counts[0] > 200, counts[2] > 200,
                      counts[1] < 40, counts[3] < 40 else { throw TrialError("逐窗所有者、AX 身份、可见性、名册或画面未同时成立") }
                result["pass"] = true
                break verification
            }
            if sticky {
                guard await wait(4, {
                    guard let snapshot = previews.currentDesktop?.snapshot, !snapshot.displays.isEmpty,
                          snapshot.native?.spaces == .observed, snapshot.native?.accessibility == .available,
                          expected().count == 3 else { return false }
                    return members().isEmpty && sourceCount() == 0
                }) else {
                    result["windowEvidence"] = ownerWitness()
                    result["readerAX"] = previews.currentDesktop?.snapshot?.native?.accessibility.rawValue ?? "noSample"
                    result["readerSpaces"] = previews.currentDesktop?.snapshot?.native?.spaces.rawValue ?? "noSample"
                    result["listedCount"] = members().count
                    result["ownerCount"] = expected().count
                    throw TrialError("已有辅助功能核对时仍出现辅助面板，或无法证明读取已完成")
                }
                result["excludedAuxiliaryPanels"] = 3
                result["windowEvidence"] = ownerWitness()
                result["pass"] = true
                break verification
            }
            guard await wait(3,{complete(3)}) else {
                result["windowEvidence"]=ownerWitness()
                let finalRead=await previews.currentDesktop?.readNow()
                result["liveReaderSlots"]=[report("notes"),report("board")].compactMap{$0}.flatMap{owner in
                    owner.windows.compactMap{slot, n in finalRead?.windows.contains{$0.metadata?.number==n} == true ? slot : nil }
                }.sorted()
                result["expected"]=expected().count; result["listed"]=members().count
                result["ordinaryScopes"]=previews.currentDesktop?.snapshot?.scopes.flatMap(\.records).filter{$0.isCurrent && $0.ordinaryUUID != nil}.count
                throw TrialError("当前桌面未包含全部三扇普通测试窗")
            }
            result["initialCardsMs"]=milliseconds(start)
            result["initialBackground"]=members().filter{$0.metadata?.onActiveDesktop == false}.count
            result["currentMembership"]=members().filter{$0.metadata?.overviewSpaceID != nil}.count
            if CommandLine.arguments.contains("--source-readback") {
                guard #available(macOS 26, *) else { throw TrialError("需要 macOS 26 单窗原始画面接口") }
                result["sourceReadback"] = try await readSourceSizes([report("notes"), report("board")].compactMap { $0 }, original: original)
                result["diagnosticOnly"] = true
            }
            guard await wait(4,{sourceCount()==3}) else {
                result["images"]=sourceCount(); result["windowEvidence"]=ownerWitness()
                if #available(macOS 14.4, *), !focusDeparture, panel.isOpaque, panel.isVisible,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == original,
                   let own = try? await SCShareableContent.currentProcess.windows.first(where: {
                       $0.windowID == panel.windowNumber && $0.owningApplication?.processID == getpid()
                   }) {
                    let cfg = SCStreamConfiguration()
                    cfg.width = 412; cfg.height = 1080; cfg.showsCursor = false
                    cfg.ignoreShadowsSingleWindow = true; cfg.includeChildWindows = false
                    if let observed = try? await SCScreenshotManager.captureImage(contentFilter: .init(desktopIndependentWindow: own), configuration: cfg) {
                        try NSBitmapImageRep(cgImage: observed).representation(using: .png, properties: [:])?
                            .write(to: folder.appendingPathComponent("partial-window-sidebar.png"), options: .atomic)
                    }
                }
                view.layoutSubtreeIfNeeded()
                if let rendered = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rendered)
                    try rendered.representation(using: .png, properties: [:])?
                        .write(to: folder.appendingPathComponent("partial-window-rendered-view.png"), options: .atomic)
                }
                let shareable=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
                if let sample=previews.currentDesktop?.snapshot {
                    result["captureEvidence"]=members().compactMap { DesktopWindowTarget($0,in:sample) }.map { t in
                        let shared = shareable.windows.filter { $0.windowID==t.key.number && $0.owningApplication?.processID==t.key.pid }
                        return ["hasFreshImage":previews.gallery.image(for:t,permitted:true) != nil,
                                "sharedSources":shared.count,"cgSharingAllowed":t.sharedSurface(visible:false,matchFrame:false),
                                "cgGeometryMatches":t.sharedSurface(visible:false,matchFrame:true),
                                "publicVisible":t.publiclyVisible,"positiveSpace":t.overviewSpace != nil] as [String:Any]
                    }
                }
                throw TrialError("三扇测试窗口没有各自的共享画面")
            }
            result["threePicturesMs"]=milliseconds(start)
            try Data().write(to:folder.appendingPathComponent("add-window"),options:.atomic)
            guard await wait(4,{complete(4)}), let add=report("board") else { throw TrialError("新窗口未自动加入") }
            result["addMs"]=milliseconds(add.changed)
            guard await wait(4,{sourceCount()==4}) else { throw TrialError("第四张窗口卡没有画面") }
            result["newPictureMs"]=milliseconds(add.changed)
            // Capture only this opaque panel. Independent swatches prove all four cards were actually rendered.
            guard #available(macOS 14.4,*), let sc=try await SCShareableContent.currentProcess.windows.first(where:{
                $0.windowID==panel.windowNumber && $0.owningApplication?.processID==getpid()
            }) else { throw TrialError("无法读取自建验证面板") }
            let cfg=SCStreamConfiguration(); cfg.width=412; cfg.height=1080; cfg.showsCursor=false; cfg.ignoreShadowsSingleWindow=true
            var counts=[Int](), literalCounts=[Int]()
            for _ in 0..<5 {
                let im=try await SCScreenshotManager.captureImage(contentFilter:.init(desktopIndependentWindow:sc),configuration:cfg)
                counts=colorCounts(im, stageShading: !sticky)
                literalCounts=colorCounts(im)
                try NSBitmapImageRep(cgImage:im).representation(using:.png,properties:[:])?.write(to:folder.appendingPathComponent("four-window-sidebar.png"),options:.atomic)
                if counts.count==4 && counts.allSatisfy({$0>200}) {
                    break
                }
                try await Task.sleep(for:.milliseconds(60))
            }
            result["colorPixels"]=counts
            result["literalColorPixels"]=literalCounts
            guard let sample = previews.currentDesktop?.snapshot else { throw TrialError("色块核对前窗口观察已失效") }
            var attributed=0
            for owner in [report("notes"), report("board")].compactMap({$0}) {
                for (slot, id) in owner.windows {
                    guard let k=Int(slot), let w=members().first(where:{$0.metadata?.number==id && $0.metadata?.pid==owner.pid}),
                          let target=DesktopWindowTarget(w,in:sample), let pixels=previews.gallery.image(for:target,permitted:true) else { continue }
                    let hues=colorCounts(pixels,stageShading: !sticky)
                    if hues.count==4 && hues[k]>200 && hues[k] == hues.max() { attributed+=1 }
                }
            }
            result["individuallyMatchedPictures"]=attributed
            guard attributed==4 else { throw TrialError("缩略图与窗口本身的测试色不对应") }
            guard counts.count==4 && counts.allSatisfy({$0>200}) else { throw TrialError("面板中没有同时显示四个真实画面") }
            try Data().write(to:folder.appendingPathComponent("close-window"),options:.atomic)
            guard await wait(4,{complete(3) && report("notes")?.windows["1"]==nil}), let closed=report("notes") else { throw TrialError("关闭的窗口未自动移除") }
            result["removeMs"]=milliseconds(closed.changed)
            if !coldBackground {
                guard let id = report("board")?.windows["2"] else { throw TrialError("无法确认将要收起的测试窗口") }
                try Data().write(to:folder.appendingPathComponent("order-out"),options:.atomic)
                guard await wait(4, {
                    guard let board = report("board"), board.orderedOut, board.windows["2"] == id else { return false }
                    return complete(2) && sourceCount() == 2
                }) else {
                    result["windowEvidence"] = ownerWitness()
                    throw TrialError("收起的原窗口仍在列表中，或剩余两扇窗口的画面不全")
                }
                result["orderedOutExcluded"] = true
                var remainingColors = [Int]()
                for _ in 0..<5 {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: .init(desktopIndependentWindow: sc), configuration: cfg)
                    remainingColors = colorCounts(image, stageShading: !sticky)
                    if remainingColors.count == 4, remainingColors[0] > 200, remainingColors[3] > 200,
                       remainingColors[1] < 40, remainingColors[2] < 40 {
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                            .write(to: folder.appendingPathComponent("two-window-sidebar.png"), options: .atomic)
                        break
                    }
                    try await Task.sleep(for: .milliseconds(60))
                }
                result["afterCloseAndOrderOutColorPixels"] = remainingColors
                guard remainingColors.count == 4, remainingColors[0] > 200, remainingColors[3] > 200,
                      remainingColors[1] < 40, remainingColors[2] < 40 else { throw TrialError("侧栏仍有已关闭或已收起窗口的测试色，或遗漏了剩余窗口画面") }
            }
            result["owners"]=pids.count; result["pass"]=true
        } catch {result["pass"]=false; result["reason"]=error.localizedDescription}
        try? Data().write(to:folder.appendingPathComponent("finish-roster"),options:.atomic)
        for _ in 0..<80 where owners.contains(where:{$0.isRunning}) {try? await Task.sleep(for:.milliseconds(30))}
        result["ownedProcessesExited"]=owners.allSatisfy{!$0.isRunning}
        result["originalFrontPreserved"]=original != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier==original
        if result["ownedProcessesExited"] as? Bool != true || result["originalFrontPreserved"] as? Bool != true { result["pass"]=false }
        if let data = try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { FileHandle.standardOutput.write(data) }
        exit(result["pass"] as? Bool == true ? 0 : 3)
    }
    @available(macOS 26, *)
    private static func readSourceSizes(_ owners: [OwnerReport], original: pid_t) async throws -> [[String: Any]] {
        guard CGPreflightScreenCaptureAccess() else { throw TrialError("验证进程没有既有的取图权限") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        var evidence = [[String: Any]]()
        for owner in owners {
            let bundles = ["net.example.nearpane-window-board": ("Sketch Board.app", "Board"),
                           "net.example.nearpane-window-selection": ("Design Notes.app", "Notes")]
            guard let app = NSRunningApplication(processIdentifier: owner.pid), let id = app.bundleIdentifier,
                  let (bundle, name) = bundles[id] else { throw TrialError("测试 PID 的 bundle 身份不符") }
            let expected = folder.appendingPathComponent(bundle).appendingPathComponent("Contents/MacOS/" + name)
                .resolvingSymlinksInPath().path
            func ownerBirth() -> UInt64? {
                var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                var info = proc_bsdinfo()
                let n = Int32(MemoryLayout.size(ofValue: info))
                guard proc_pidpath(owner.pid, &bytes, UInt32(bytes.count)) > 0,
                      URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().path == expected,
                      proc_pidinfo(owner.pid, PROC_PIDTBSDINFO, 0, &info, n) == n else { return nil }
                return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
            }
            guard let birth = ownerBirth(), birth > 0 else { throw TrialError("测试进程的可执行文件或出生代际不符") }
            for (slot, number) in owner.windows.sorted(by: { $0.key < $1.key }) {
                let matches = content.windows.filter { $0.windowID == number && $0.owningApplication?.processID == owner.pid }
                func valid() -> Bool {
                    guard let row = WindowSurfaceRecord(number: number), row.pid == owner.pid, row.layer == 0, row.allowsContent,
                          ownerBirth() == birth, !app.isTerminated, CGPreflightScreenCaptureAccess() else { return false }
                    return NSWorkspace.shared.frontmostApplication?.processIdentifier == original
                }
                guard valid(), matches.count == 1, let window = matches.first, let size = owner.frameSizes[slot], size.count == 2 else {
                    throw TrialError("无法确认合成窗口的唯一共享身份")
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = Double(filter.pointPixelScale)
                var row: [String: Any] = ["slot": slot, "ownerSize": size, "scale": scale,
                    "scWindow": [window.frame.width, window.frame.height],
                    "filterPoints": [filter.contentRect.width, filter.contentRect.height]]
                for mode in ["native", "requested", "streamRequested"] {
                    let config = SCScreenshotConfiguration()
                    config.dynamicRange = .sdr; config.showsCursor = false; config.includeChildWindows = false
                    config.ignoreShadows = true; config.ignoreClipping = true
                    if mode == "requested" {
                        config.width = Int((size[0]*scale).rounded()); config.height = Int((size[1]*scale).rounded())
                    }
                    guard valid() else { throw TrialError("目标或前台变化") }
                    let image: CGImage
                    do {
                        if mode == "streamRequested" {
                            let stream = SCStreamConfiguration()
                            stream.width = Int((size[0]*scale).rounded()); stream.height = Int((size[1]*scale).rounded())
                            stream.ignoreGlobalClipSingleWindow = true; stream.ignoreShadowsSingleWindow = true
                            stream.includeChildWindows = false; stream.showsCursor = false; stream.capturesAudio = false
                            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: stream)
                        } else {
                            let shot = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
                            guard let bitmap = shot.sdrImage else { throw TrialError("无 SDR 画面") }
                            image = bitmap
                        }
                    } catch {
                        let e = error as NSError
                        row[mode + "Error"] = [e.domain, String(e.code)]
                        continue
                    }
                    guard valid() else { throw TrialError("原窗口或权限已变") }
                    row[mode] = [image.width, image.height]
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(
                        to: folder.appendingPathComponent("source-" + slot + "-" + mode + ".png"), options: .atomic)
                }
                evidence.append(row)
            }
        }
        return evidence
    }

    private static func colorCounts(_ image: CGImage, stageShading: Bool = false) -> [Int] {
        guard let ctx=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
              let data=ctx.data else{return []}
        ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let bytes=data.assumingMemoryBound(to:UInt8.self)
        var counts=Array(repeating:0,count:swatches.count)
        for i in stride(from:0,to:image.width*image.height*4,by:4) where bytes[i+3] > 220 {
            let r=Int(bytes[i]), g=Int(bytes[i+1]), b=Int(bytes[i+2])
            guard max(r,g,b)-min(r,g,b)>45 else { continue }
            for (k,c) in swatches.enumerated() {
                if abs(r-c.0)<16 && abs(g-c.1)<16 && abs(b-c.2)<16 { counts[k]+=1; continue }
                // Stage Manager applies a luminance gradient to individual non-frontmost
                // surfaces. Match chromaticity separately and retain literal counts too.
                guard stageShading else { continue }
                let total=Double(r+g+b), reference=Double(c.0+c.1+c.2)
                if abs(Double(r)/total-Double(c.0)/reference)<0.05 &&
                   abs(Double(g)/total-Double(c.1)/reference)<0.05 &&
                   abs(Double(b)/total-Double(c.2)/reference)<0.05 { counts[k]+=1 }
            }
        }
        return counts
    }
#endif
}
