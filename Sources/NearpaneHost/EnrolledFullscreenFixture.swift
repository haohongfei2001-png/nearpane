#if canImport(SaytileKit) && canImport(RiftletCore)
import AppKit
import CryptoKit
import Security
import NearpaneCore
import NearpaneUI

/// Available only to the binary-bound, disposable secondary-screen acceptance profile.
@MainActor final class EnrolledFullscreenFixture {
    private struct Consent: Decodable {
        let run: UUID, boot: String, securityID: UInt32, secondaryDisplay: String, source: String, target: String
        let permitsCalibrationAndThreeRoundTrips: Bool, permitsSingleWindowFullscreen: Bool?, permitsFullscreenToolObservation: Bool?
        let starts, ends: Date
    }
    private struct Origin: Decodable {
        let number: UInt32, record: String, build: String, frontPID: Int32, currents: [String:String]
    }
    private struct Return: Decodable {
        let run: UUID, revision: String, source, returned: String
    }
    private let run: UUID, hostRun: String, root: URL, executable: URL, display: String
    private let witnessHash, readerHash: String, consent: Consent, deadline: Double
    private let witnessCodeDirectory: Data
    private let directoryFD: Int32
    private let output: URL
    private var token: EnrolledFullscreenObservation?, enrolledElement: AXUIElement?, lastRevision: UInt64 = 0
    private var timer: Timer?, latest: FullscreenDisplaySample?, lastReceipt: Data?
    private var phase = "waiting"
    private var retired = false
    private let finish: URL
    private let domains: EmbeddedModules
    private weak var edge: NSWindow?

    private static func reject() -> CocoaError { CocoaError(.fileReadNoPermission) }

    /// A signed writer publishes under its private run directory. Never follow a link or
    /// read a partial, oversized or substituted file as a receipt.
    private static func data(_ name: String, at fd: Int32, limit: Int = 256_000) throws -> Data {
        let f = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard f >= 0 else { throw reject() }
        let file = FileHandle(fileDescriptor: f, closeOnDealloc: true)
        var info = stat()
        guard fstat(f, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size > 0, info.st_size <= limit,
              let data = try file.read(upToCount: limit + 1), data.count == info.st_size else { throw reject() }
        return data
    }
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined()
    }

    private static func codeDirectory(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, .init(rawValue:kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    }

    init(session: NativeAcceptanceSession, display: String, domains: EmbeddedModules, edge: NSWindow?) throws {
        let env = ProcessInfo.processInfo.environment
        guard CandidateProfile.selected,
              let h = env["NEARPANE_ACCEPTANCE_RUN"], UUID(uuidString:h)?.uuidString.lowercased() == h,
              let text = env["NEARPANE_SPACE_WITNESS_RUN"], let run = UUID(uuidString:text),
              let path = env["NEARPANE_SPACE_WITNESS_EXECUTABLE"], path.hasPrefix("/"),
              let wh = env["NEARPANE_SPACE_WITNESS_SHA256"], let rh = env["NEARPANE_SPACE_READER_SHA256"],
              wh.count == 64, rh.count == 64, UUID(uuidString:display) != nil else { throw Self.reject() }
        let exe = URL(fileURLWithPath:path), bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reader = bundle.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader")
        var code: SecStaticCode?
        guard EnrolledFullscreenObservation.matchesExecutablePath(enrolled: reader.path, reported: reader.path),
              Bundle(url:bundle)?.bundleIdentifier == "org.nearpane.lab.NearpaneSpaceWitness",
              let bundlePath = Bundle(url:bundle)?.executableURL?.path,
              EnrolledFullscreenObservation.matchesExecutablePath(enrolled: path, reported: bundlePath),
              SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue:kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess,
              let cd = Self.codeDirectory(code), !cd.isEmpty,
              try Self.sha(Data(contentsOf:exe)) == wh, try Self.sha(Data(contentsOf:reader)) == rh else { throw Self.reject() }
        let cache = try FileManager.default.url(for:.cachesDirectory, in:.userDomainMask, appropriateFor:nil, create:false)
        let root = cache.appendingPathComponent("Nearpane-P431-" + run.uuidString)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.reject() }
        var completed = false
        defer { if !completed { close(fd) } }
        var info = stat(), sid: SecuritySessionId = 0, flags = SessionAttributeBits()
        var boot = [CChar](repeating:0, count:80), count = boot.count
        guard fstat(fd,&info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
              SessionGetInfo(callerSecuritySession, &sid, &flags) == errSecSuccess, sid != 0,
              sysctlbyname("kern.bootsessionuuid",&boot,&count,nil,0) == 0 else { throw Self.reject() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let grant = try decoder.decode(Consent.self, from:Self.data("unattended-consent.ready", at:fd))
        let now = Date()
        guard grant.run == run, grant.boot == Self.sha(Data(String(cString:boot).utf8)), grant.securityID == sid,
              grant.secondaryDisplay == display, !grant.source.isEmpty, grant.target.isEmpty,
              grant.permitsCalibrationAndThreeRoundTrips == false, grant.permitsSingleWindowFullscreen == true,
              grant.permitsFullscreenToolObservation == true, grant.starts <= now, now < grant.ends,
              grant.ends.timeIntervalSince(grant.starts) <= 900 else { throw Self.reject() }
        let output = session.directory.appendingPathComponent("fullscreen-tools-host-" + h + ".json")
        let finish = session.directory.appendingPathComponent("finish-" + h)
        guard !FileManager.default.fileExists(atPath: output.path), !FileManager.default.fileExists(atPath: finish.path) else { throw Self.reject() }
        self.output = output; self.finish = finish
        self.run = run; hostRun = h; self.root = root; self.display = display
        witnessCodeDirectory = cd
        executable = exe; witnessHash = wh; readerHash = rh; directoryFD = fd; consent = grant
        deadline = ProcessInfo.processInfo.systemUptime + grant.ends.timeIntervalSince(now)
        self.domains = domains; self.edge = edge; completed = true
    }
    deinit { close(directoryFD) }

    func sample(_ id: String) -> FullscreenDisplaySample? { id == display ? latest : nil }

    func start(refresh: @escaping @MainActor () -> Void) {
        let tick: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let now = Date(), up = ProcessInfo.processInfo.systemUptime
            if now < consent.starts || now >= consent.ends || up >= deadline ||
                FileManager.default.fileExists(atPath: finish.path) {
                stop(); NSApp.terminate(nil); return
            }
            do { latest = try read(now:now, uptime:up) }
            catch { latest = nil }
            refresh()
            do { try publish() } catch { stop(); NSApp.terminate(nil) }
        }
        let timer = Timer(timeInterval:0.2, repeats:true) { _ in MainActor.assumeIsolated { tick() } }
        self.timer = timer
        RunLoop.main.add(timer, forMode:.common)
        tick()
    }
    func stop() { timer?.invalidate(); timer = nil; latest = nil }

    private func liveWindow(_ c: EnrolledFullscreenObservation, frame: SurfaceRect, fullscreen: Bool) -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String:Any]
        guard session?[kCGSessionOnConsoleKey as String] as? Bool == true,
              session?[kCGSessionUserIDKey as String] as? UInt32 == getuid(),
              session?["CGSSessionScreenIsLocked"] as? Bool != true, NSScreen.screensHaveSeparateSpaces,
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier == c.pid,
              let reported = app.executableURL?.path,
              EnrolledFullscreenObservation.matchesExecutablePath(enrolled: executable.path, reported: reported), AXIsProcessTrusted(),
              !NSApp.isActive, NSApp.keyWindow == nil, NSApp.mainWindow == nil else { return false }
        var birth = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue:birth))
        guard proc_pidinfo(c.pid, PROC_PIDTBSDINFO, 0, &birth, size) == size, birth.pbi_pid == UInt32(c.pid),
              birth.pbi_uid == getuid(), birth.pbi_start_tvsec * 1_000_000 + birth.pbi_start_tvusec == c.launch else { return false }
        if enrolledElement == nil {
            var guest: SecCode?, running: SecStaticCode?
            let criteria = [kSecGuestAttributePid as String: c.pid] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil,criteria,[],&guest) == errSecSuccess, let guest,
                  SecCodeCheckValidity(guest,[],nil) == errSecSuccess,
                  SecCodeCopyStaticCode(guest,[],&running) == errSecSuccess, let running,
                  Self.codeDirectory(running) == witnessCodeDirectory else { return false }
        }
        func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(e,key as CFString,&value) == .success ? value : nil
        }
        let owner = AXUIElementCreateApplication(c.pid)
        guard AXUIElementSetMessagingTimeout(owner,0.12) == .success,
              let raw = attr(owner,kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let focused = raw as! AXUIElement
        var pid:Int32 = 0
        guard AXUIElementSetMessagingTimeout(focused,0.12) == .success,
              AXUIElementGetPid(focused,&pid) == .success, pid == c.pid,
              attr(focused,kAXIdentifierAttribute) as? String == run.uuidString + "/A",
              attr(focused,"AXFullScreen") as? Bool == fullscreen,
              enrolledElement.map({ CFEqual($0,focused) }) != false else { return false }
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow,c.number) as? [[String:Any]]
        guard rows?.count == 1, let row = rows?.first, row[kCGWindowOwnerPID as String] as? Int32 == c.pid,
              row[kCGWindowNumber as String] as? UInt32 == c.number, row[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary, let cg = CGRect(dictionaryRepresentation:bounds),
              NSScreen.screens.count == 2, CGDisplayBounds(CGMainDisplayID()).intersection(cg).isEmpty,
              NSScreen.screens.contains(where: { screen in
                  guard let n = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else { return false }
                  let id = n.uint32Value
                  guard id != CGMainDisplayID(), CGDisplayIsActive(id) != 0, CGDisplayIsInMirrorSet(id) == 0,
                        CGDisplayBounds(id).contains(cg),
                        let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
                  return CFUUIDCreateString(nil,u) as String == display
              }),
              let p = attr(focused,kAXPositionAttribute), let s = attr(focused,kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return false }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&point), AXValueGetValue(s as! AXValue,.cgSize,&dimensions) else { return false }
        for f in [cg, CGRect(origin:point,size:dimensions)] where f.isEmpty ||
            max(abs(f.minX-frame.x),abs(f.minY-frame.y),abs(f.width-frame.width),abs(f.height-frame.height)) > 2 { return false }
        enrolledElement = focused
        return true
    }

    private func read(now: Date, uptime: Double) throws -> FullscreenDisplaySample? {
        phase = "waiting"
        let decoder = JSONDecoder()
        let c = try decoder.decode(EnrolledFullscreenObservation.self, from:Self.data("fullscreen-tools-challenge.json", at:directoryFD))
        if let token, token != c { retired = true }
        guard !retired, c.run == run, c.boot == consent.boot, c.display == display, c.source == consent.source,
              c.build == ProcessInfo.processInfo.operatingSystemVersionString, c.witnessSHA256 == witnessHash, c.readerSHA256 == readerHash,
              c.pid > 1, c.launch > 0, c.number > 0, c.revision > 0, c.expiresUptime.isFinite,
              c.expiresUptime <= deadline + 0.5 else { throw Self.reject() }
        token = c
        let origin = try decoder.decode(Origin.self, from:Self.data("origin-A.json", at:directoryFD))
        guard origin.record == c.source, origin.build == c.build, origin.number == c.number, origin.frontPID == c.pid else { throw Self.reject() }
        let returned = try? decoder.decode(Return.self, from:Self.data("fullscreen-exit-confirmed.json", at:directoryFD))
        let revision: UInt64
        let file: String
        let expires: Double
        if let returned {
            guard returned.run == run, returned.source == c.source, returned.returned == c.source,
                  let r = UInt64(returned.revision), r > c.revision else { throw Self.reject() }
            revision = r; file = "snapshot-\(r).json"; expires = deadline
        } else {
            guard uptime < c.expiresUptime else { return nil }
            let names = try FileManager.default.contentsOfDirectory(atPath:root.path)
            guard names.count <= 4096 else { throw Self.reject() }
            let prefix = "fullscreen-snapshot-"
            guard let r = names.compactMap({ name -> UInt64? in
                guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
                return UInt64(name.dropFirst(prefix.count).dropLast(5))
            }).max() else { return nil }
            revision = r; file = "fullscreen-snapshot-\(r).json"; expires = min(c.expiresUptime,deadline)
        }
        guard revision >= lastRevision else { return nil }
        let snap = try decoder.decode(DesktopSnapshot.self,from:Self.data(file,at:directoryFD))
        guard snap.revision == revision, let actual = snap.windows.first?.metadata?.globalFrame,
              liveWindow(c, frame:actual, fullscreen:returned == nil), let sample = c.sample(snap,sourceCurrents:origin.currents,returned:returned != nil,date:now,uptime:uptime,validUntil:expires) else { return nil }
        lastRevision = revision; phase = returned == nil ? "native" : "ordinaryReturned"
        return sample
    }

    private func publish() throws {
        guard let token else { return }
        let windows = NSApp.windows.filter { $0.identifier?.rawValue == "np.fullscreen.panel" && $0.isVisible }
        guard windows.count <= 1 else { throw Self.reject() }
        if let w = windows.first {
            guard let s = w.screen, let n = s.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
                  n.uint32Value != CGMainDisplayID(), CGDisplayIsInMirrorSet(n.uint32Value) == 0,
                  let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
                  CFUUIDCreateString(nil,u) as String == display, s.frame.contains(w.frame) else { throw Self.reject() }
        }
        func instance(_ object: AnyObject) -> String {
            Self.sha(Data((run.uuidString + String(UInt(bitPattern:ObjectIdentifier(object)))).utf8))
        }
        let r: [String: Any] = ["run":run.uuidString, "token":token.token.uuidString, "acceptanceRun":hostRun,
            "hostPID":getpid(), "pid":token.pid, "launch":token.launch, "number":token.number, "display":display,
            "phase":phase, "revision":lastRevision, "tool":windows.first?.windowNumber ?? 0, "edgeVisible":edge?.isVisible ?? false,
            "frontPID":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "hostKey":NSApp.keyWindow != nil, "hostMain":NSApp.mainWindow != nil, "hostActive":NSApp.isActive,
            "voiceInstance":instance(domains.voice), "trayInstance":instance(domains.tray),
            "recordings":domains.voice.openRecordingIDs.map(\.uuidString), "trayCount":domains.tray.visibleIDs.count]
        let data = try JSONSerialization.data(withJSONObject:r,options:.sortedKeys)
        if lastReceipt != data { try data.write(to:output,options:.atomic); lastReceipt = data }
    }
}
#endif
