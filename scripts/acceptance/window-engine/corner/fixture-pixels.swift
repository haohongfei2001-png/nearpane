import AppKit
import ScreenCaptureKit
import Security

enum CornerFixturePixels {
    typealias Link = StageFixtureVisualLink

    private static func listenOnce(_ nonce: UUID) throws -> Int32 {
        let path = try Link.path(nonce), listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Link.Fault.endpoint }
        defer { close(listener) }
        try Link.configure(listener)
        try Link.address(path) { Darwin.bind(listener,$0,$1) }
        defer { unlink(path) }
        guard chmod(path,0o600) == 0, listen(listener,1) == 0 else { throw Link.Fault.endpoint }
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&ready,1,25_000) == 1, ready.revents & Int16(POLLIN) != 0 else { throw Link.Fault.endpoint }
        let client = accept(listener,nil,nil)
        guard client >= 0 else { throw Link.Fault.endpoint }
        do { try Link.configure(client); return client } catch { close(client); throw error }
    }

    private static func listed(_ r: Link.Request) throws -> CGRect {
        let now = DispatchTime.now().uptimeNanoseconds
        let expected = "/private/tmp/nearpane-membership." + r.session.uuidString.lowercased() +
            "/Membership Window.app/Contents/MacOS/MembershipWindow"
        var path = [CChar](repeating:0,count:4096)
        guard now >= r.began, now - r.began < 6_000_000_000, Link.birth(r.pid) == r.birth,
              proc_pidpath(r.pid,&path,UInt32(path.count)) > 0, String(cString:path) == expected,
              try Link.signer([kSecGuestAttributePid as String: r.pid],Link.fixtureID) == r.cdhash,
              NPReadOnlySpacesOpen() == 1,
              NPCornerObserverMatchesHome(r.display.uuidString as CFString, r.space.uuidString as CFString, r.native),
              NPReadWindowSpaces(r.window) as? [UInt64] == [r.native],
              (NPReadCatalogSpaceWindowNumbers(r.native) as? [UInt32])?.contains(r.window) == true,
              let inventory = CGWindowListCopyWindowInfo(.optionIncludingWindow,r.window) as? [[String:Any]], inventory.count == 1,
              let row = inventory.first, row[kCGWindowOwnerPID as String] as? pid_t == r.pid,
              row[kCGWindowNumber as String] as? UInt32 == r.window, row[kCGWindowLayer as String] as? Int == 0,
              row[kCGWindowIsOnscreen as String] as? Bool == true, row[kCGWindowAlpha as String] as? Double == 1,
              let raw = row[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation:raw),
              frame.width == 220, (110...160).contains(frame.height), Link.birth(r.pid) == r.birth else { throw Link.Fault.frame }
        return frame
    }
    /// A tiny stripe of the registered fixture's own window. No composite desktop image is requested.
    private static func stripes(_ image: CGImage, session: UUID) throws -> Int {
        let w = 160, h = 8
        var rgba = [UInt8](repeating:0,count:w*h*4)
        guard image.width == w, image.height == h, let color = CGColorSpace(name:CGColorSpace.sRGB) else { throw Link.Fault.frame }
        let bits = withUnsafeBytes(of: session.uuid) { Array($0.prefix(2)) }
        return try rgba.withUnsafeMutableBytes { pixels in
            guard let context = CGContext(data:pixels.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Link.Fault.frame }
            context.setBlendMode(.copy)
            context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
            return (0..<16).filter { index in
                let green = bits[index / 8] & (1 << (index % 8)) != 0
                return (3...4).allSatisfy { y in (4...5).allSatisfy { dx in
                    let p = 4 * (y*w+index*10+dx), r = pixels[p], g = pixels[p+1], b = pixels[p+2]
                    return pixels[p+3] == 255 && (green ? (g > 170 && r < 80 && b < 90) : (r > 165 && g < 75 && b > 160))
                } }
            }.count
        }
    }
    @MainActor private static func sample(_ r: Link.Request) async -> Link.Reply {
        var samples = [Link.Sample]()
        let access = CGPreflightScreenCaptureAccess()
        func reply(_ status: String, _ reason: String) -> Link.Reply {
            .init(request:r,observerPID:getpid(),screenAccess:access,samples:samples,status:status,reason:reason)
        }
        guard access else { return reply("BLOCKED","observerScreenCaptureDenied") }
        do {
            let frame = try listed(r)
            let inventory = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
            let exact = inventory.windows.filter { $0.windowID == r.window && $0.owningApplication?.processID == r.pid && $0.frame == frame }
            guard exact.count == 1, let window = exact.first else { throw Link.Fault.frame }
            let filter = SCContentFilter(desktopIndependentWindow:window)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = CGRect(x:0,y:floor(frame.height/2)-4,width:frame.width,height:8)
            cfg.width = 160; cfg.height = 8; cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true; cfg.ignoreGlobalClipSingleWindow = true
            cfg.scalesToFit = true; cfg.preservesAspectRatio = false
            for index in 0..<2 {
                if index > 0 { try await Task.sleep(for:.milliseconds(80)) }
                guard try listed(r) == frame else { throw Link.Fault.stale }
                let frameImage = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:cfg)
                guard try listed(r) == frame else { throw Link.Fault.stale }
                samples.append(.init(time:DispatchTime.now().uptimeNanoseconds,matchingStripes:try stripes(frameImage,session:r.session)))
            }
            return samples.allSatisfy { $0.matchingStripes == 16 } ? reply("PASS","registeredFixturePixelsTwice") : reply("FAIL","fixtureMarkerMismatch")
        } catch { return reply("UNKNOWN",(error as? Link.Fault)?.rawValue ?? "captureUnavailable") }
    }

    static func serve(_ session: UUID) async throws {
        let fd = try await Task.detached { try listenOnce(session) }.value
        defer { close(fd) }
        let host = try Link.peer(fd,identifier:Link.hostID)
        let r = try Link.receive(Link.Request.self,from:fd)
        guard r.session == session, r.challenge != session, r.pid != host.pid else { throw Link.Fault.untrustedPeer }
        let measured = await sample(r)
        let final = try Link.peer(fd,identifier:Link.hostID)
        guard final.pid == host.pid && final.cdhash == host.cdhash else { throw Link.Fault.untrustedPeer }
        try Link.send(measured,to:fd)
    }
}
