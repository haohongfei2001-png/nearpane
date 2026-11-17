#if !TARGET_WINDOWS
import AppKit
import CReadOnlySpaces
import NearpaneCore
@preconcurrency import ScreenCaptureKit
import SwiftUI
@testable import NearpaneUI

private final class GalleryPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor enum GalleryTrial {
    // This test is independent of current-Space admission and never feeds an off-Space
    // window into the product gallery. Distinct Return values keep the scope explicit.
    static func capturedCards(owner: Witness, destination: URL) async throws -> [String:Any] {
        guard CGPreflightScreenCaptureAccess(), owner.numbers.count == 2, Set(owner.numbers).count == 2 else {
            throw OrdinaryWindowFailure("screen capture permission or fixture identity unavailable")
        }
        let shareable = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
        var images = [CGImage]()
        for n in owner.numbers {
            let matches = shareable.windows.filter { $0.windowID == n && $0.windowLayer == 0 &&
                $0.owningApplication?.bundleIdentifier == "net.example.nearpane-window-selection" &&
                $0.owningApplication?.processID == owner.pid }
            guard matches.count == 1, let window = matches.first else { throw OrdinaryWindowFailure("fixture missing from shareable catalog") }
            let cfg = SCStreamConfiguration()
            cfg.width = 268; cfg.height = 146; cfg.showsCursor = false; cfg.ignoreShadowsSingleWindow = true
            if #available(macOS 14.2, *) { cfg.includeChildWindows = false }
            images.append(try await SCScreenshotManager.captureImage(contentFilter:.init(desktopIndependentWindow:window),configuration:cfg))
        }
        let first = counts(images[0]), second = counts(images[1])
        let view = NSHostingView(rootView:VStack(alignment:.leading,spacing:8) {
            Text("当前桌面").font(.caption.weight(.semibold))
            DesktopWindowCard(label:"设计草图 · 1",icon:nil,image:images[0])
            DesktopWindowCard(label:"项目笔记 · 2",icon:nil,image:images[1])
        }.padding(8).frame(width:232).background(Color(nsColor:.windowBackgroundColor)))
        view.frame.size = view.fittingSize
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw OrdinaryWindowFailure("fixture card bitmap unavailable") }
        view.cacheDisplay(in:view.bounds,to:rep)
        guard let cg = rep.cgImage else { throw OrdinaryWindowFailure("fixture card render unavailable") }
        let cards = counts(cg)
        let ok = first.count == 2 && second.count == 2 && cards.count == 2 && first[0]>100 && first[1]<50 && second[1]>100 && second[0]<50 && cards.allSatisfy { $0 > 100 }
        if ok, let png = rep.representation(using:.png,properties:[:]) {
            try png.write(to:destination.appendingPathComponent("captured-window-cards.png"),options:.atomic)
        }
        return ["pass":ok,"firstSwatches":first,"secondSwatches":second,"cardSwatches":cards]
    }

    static func run(owner: Witness, launch: UInt64, frames: [[Double]], destination: URL, originalFront: Int32, choose: ((UInt32) -> Bool)? = nil, safeToPress: (() -> Bool)? = nil) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess(), owner.numbers.count == 2, frames.count == 2,
              let screen = NSScreen.screens.first, let d = SystemScreens.geometry().first else {
            throw OrdinaryWindowFailure("gallery fixture permission or display")
        }
        let host = HostSession(store: MemoryConfigurationStore(), includeSampleModules: false)
        await host.start()
        defer { host.stop() }
        host.bus.resetDesktopSession()
        let session = UUID()
        var revision: UInt64 = 0
        func publishSample() throws -> DesktopSnapshot {
            let t = Date(), uptime = ProcessInfo.processInfo.systemUptime
            let before = Set((NSWindow.windowNumbers(options:.allApplications) ?? []).map(\.uint32Value))
            guard let list = NPReadVisibleWindowDescriptions(owner.numbers,Int32(owner.numbers.count)) as? [[String:Any]],
                  list.count == owner.numbers.count else { throw OrdinaryWindowFailure("owned surfaces unavailable") }
            revision += 1
            let windows = try list.enumerated().map { index,row -> WindowObservation in
                guard let n = row[kCGWindowNumber as String] as? UInt32, owner.numbers.contains(n), before.contains(n),
                      row[kCGWindowOwnerPID as String] as? Int32 == owner.pid, row[kCGWindowLayer as String] as? Int == 0,
                      row[kCGWindowIsOnscreen as String] as? Bool == true, let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation:bounds) else { throw OrdinaryWindowFailure("scoped surface changed") }
                let f = SurfaceRect(x:r.minX,y:r.minY,width:r.width,height:r.height)
                return WindowObservation(id:"\(revision)/\(n)",displayID:d.id,bounds:f,membership:.unknown,confidence:.unknown,
                    metadata:.init(number:n,pid:owner.pid,launchMicroseconds:launch,element:nil,globalFrame:f,
                                   frontToBack:index,minimized:nil,fullScreen:nil,isOnscreen:true,onActiveDesktop:true))
            }
            let after = Set((NSWindow.windowNumbers(options:.allApplications) ?? []).map(\.uint32Value))
            guard Set(owner.numbers).isSubset(of:after) else { throw OrdinaryWindowFailure("active desktop changed") }
            let sample = DesktopSnapshot.observed(.init(session:session,revision:revision,parentPID:getpid(),
                fixtureWindows:owner.numbers,anchors:[],experimentalSpaces:false),from:t,to:Date(),build:"isolated",
                topology:d.id,consistent:true,separateSpaces:NSScreen.screensHaveSeparateSpaces,
                displays:[.init(id:d.id,frame:d.frame,rotationDegrees:Int(d.rotationDegrees),backingScale:d.backingScale,usable:d.visibleFrame)],
                scopes:[],windows:windows,evidence:.init(population:.markedFixture,accessibility:.denied,spaces:.disabled,
                    rows:[],windowLimitReached:false,beganUptime:uptime,endedUptime:ProcessInfo.processInfo.systemUptime))
            guard host.bus.acceptDesktop(sample) else { throw OrdinaryWindowFailure("live fixture snapshot rejected") }
            return sample
        }
        let sample = try publishSample()
        let windows = owner.numbers.compactMap { n in sample.windows.first(where:{ $0.metadata?.number == n }) }
        let previews = WindowContentPreview(permitsGalleryWindow:{ $0.pid == owner.pid && $0.birth == launch && owner.numbers.contains($0.number) })
        let pointer = WorkspacePointerRegistry(), display = SurfaceDisplay()
        display.id = d.id; display.interactionVisible = true; display.pointer = pointer; pointer.windowPreviews = previews
        previews.setVisible(true,on:d.id)
        let size = NSSize(width:232,height:448)
        let view = NSHostingView(rootView:DesktopSurface(host:host,displayID:d.id,enabled:true,display:display)
            .frame(width:size.width,height:size.height).background(Color(nsColor:.windowBackgroundColor)))
        let panel = GalleryPanel(contentRect:NSRect(origin: .zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:true)
        panel.isReleasedWhenClosed = false; panel.contentView = view; panel.ignoresMouseEvents = choose == nil
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.canJoinAllApplications]
        panel.isOpaque = true; panel.backgroundColor = .windowBackgroundColor; panel.hidesOnDeactivate = false
        panel.setFrameOrigin(.init(x:screen.visibleFrame.minX + 14,y:screen.visibleFrame.minY + 20))
        panel.orderBack(nil)
        defer { previews.setVisible(false,on:d.id); panel.orderOut(nil); panel.close() }
        let targets = windows.compactMap { DesktopWindowTarget($0,in:sample) }
        guard targets.count == 2 else { throw OrdinaryWindowFailure("fixture target identity") }
        var content = [CGImage]()
        for _ in 0..<55 {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFront, !panel.isKeyWindow else {
                throw OrdinaryWindowFailure("foreground changed during readback")
            }
            content = targets.compactMap { previews.gallery.image(for:$0,permitted:true) }
            if content.count == 2 { break }
            try await Task.sleep(for:.milliseconds(140))
        }
        guard content.count == 2 else { return ["pass":false,"sourceCount":content.count] }
        try await Task.sleep(for:.milliseconds(230))
        // The panel is opaque and contains only our two enrolled fixtures.
        guard #available(macOS 14.4, *) else { throw OrdinaryWindowFailure("panel readback needs macOS 14.4") }
        let available = try await SCShareableContent.currentProcess
        guard let own = available.windows.first(where: { $0.windowID == UInt32(panel.windowNumber) && $0.owningApplication?.processID == getpid() })
        else { throw OrdinaryWindowFailure("own panel unavailable") }
        let config = SCStreamConfiguration()
        config.width = Int(size.width * 2); config.height = Int(size.height * 2)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        let result = try await SCScreenshotManager.captureImage(contentFilter:.init(desktopIndependentWindow:own),configuration:config)
        let first = counts(content[0]), second = counts(content[1]), panelColors = counts(result)
        let pass = first.count == 2 && second.count == 2 && panelColors.count == 2 && first[0]>100 && first[1]<50 && second[1]>100 && second[0]<50 && panelColors.allSatisfy { $0>100 }
        if pass, let data = NSBitmapImageRep(cgImage:result).representation(using:.png,properties:[:]) {
            try data.write(to:destination.appendingPathComponent("window-gallery.png"),options:.atomic)
        }
        var confirmed = [UInt32]()
        if let choose, let safeToPress, pass {
            // A local AppKit click is addressed to this panel's actual WindowServer number.
            // Its position comes from the two independently confirmed pixels on this panel.
            for index in [0,1,0] {
                _ = try publishSample()
                await Task.yield()
                guard safeToPress() else { throw OrdinaryWindowFailure("source focus or ordinary Space changed") }
                guard let point = Self.center(of: index, in: result, size: size, firstIsAboveSecond: owner.numbers[0] < owner.numbers[1]),
                      view.hitTest(view.convert(point,from:nil)) != nil,
                      Self.click(point, in:panel) else { throw OrdinaryWindowFailure("could not click the observed card") }
                for _ in 0..<35 {
                    if choose(owner.numbers[index]) { break }
                    try await Task.sleep(for:.milliseconds(65))
                }
                if !choose(owner.numbers[index]) { break }
                confirmed.append(owner.numbers[index])
            }
        }
        return ["pass":pass && (choose == nil || confirmed == [owner.numbers[0],owner.numbers[1],owner.numbers[0]]),
            "sourceCount":content.count,"firstSwatches":first,"secondSwatches":second,
            "panelSwatches":panelColors,"cardPressKeyMain":confirmed,"liveSampleCount":revision]
    }
    private static func click(_ point: NSPoint, in panel: NSPanel) -> Bool {
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:time,windowNumber:panel.windowNumber,
                context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0)
        }
        guard panel.isVisible, let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        panel.sendEvent(down)
        panel.sendEvent(up)
        return true
    }

    private static func center(of index: Int, in im: CGImage, size: NSSize, firstIsAboveSecond: Bool) -> NSPoint? {
        guard let context = CGContext(data:nil,width:im.width,height:im.height,bitsPerComponent:8,bytesPerRow:im.width*4,
              space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }
        context.draw(im,in:.init(x:0,y:0,width:im.width,height:im.height))
        let pixels = data.assumingMemoryBound(to:UInt8.self)
        var points = [CGPoint.zero,CGPoint.zero], totals = [0,0]
        for y in 0..<im.height {
            for x in 0..<im.width {
                let p = pixels + (y*im.width+x)*4
                let green = abs(Int(p[0])-28)<14 && abs(Int(p[1])-133)<14 && abs(Int(p[2])-82)<14
                let blue = abs(Int(p[0])-46)<14 && abs(Int(p[1])-66)<14 && abs(Int(p[2])-176)<14
                if !green && !blue { continue }
                let n = green ? 0 : 1
                totals[n] += 1; points[n].x += CGFloat(x); points[n].y += CGFloat(y)
            }
        }
        guard totals.allSatisfy({ $0 > 100 }) else { return nil }
        let y0 = points[0].y/CGFloat(totals[0]), y1 = points[1].y/CGFloat(totals[1])
        let relative = points[index].y / CGFloat(totals[index]) / CGFloat(im.height)
        let bottom = (y0 < y1) == firstIsAboveSecond ? 1-relative : relative
        return NSPoint(x:points[index].x/CGFloat(totals[index])/CGFloat(im.width)*size.width,y:bottom*size.height)
    }

    private static func counts(_ im: CGImage) -> [Int] {
            guard let ctx = CGContext(data:nil,width:im.width,height:im.height,bitsPerComponent:8,bytesPerRow:4 * im.width,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
                  let data = ctx.data else { return [] }
            ctx.draw(im,in:.init(x:0,y:0,width:im.width,height:im.height))
            let p = data.assumingMemoryBound(to:UInt8.self)
            var c = [0,0]
            for i in stride(from:0,to:im.width*im.height*4,by:4) {
                let r = Int(p[i]),g = Int(p[i+1]),b = Int(p[i+2])
                if abs(r-28)<14 && abs(g-133)<14 && abs(b-82)<14 { c[0]+=1 }
                if abs(r-46)<14 && abs(g-66)<14 && abs(b-176)<14 { c[1]+=1 }
            }
            return c
        }

}
#endif
