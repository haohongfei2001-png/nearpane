#if DEBUG
import AppKit
import Darwin
import NearpaneCore
import NearpaneOrdinaryWindowRuntime
import Security

/// Restricted first-evidence path. Only two direct children of the isolated signed
/// debug Host can be named by the genuine R4 drop. No PID, window or input point
/// is accepted from a command line or a receipt.
@MainActor package final class AppleStageMergeFixture {
    private struct Child {
        let process: Process, image: OrdinaryProcessImage, signature: Data, identifier: String
    }
    private static var active: AppleStageMergeFixture?
    private let directory: URL, nonce: UUID
    private let display: String, desktop: UUID, record: String
    private let ordinary: @MainActor () -> Bool
    private var children = [Child]()
    private var attempted = false
    private var tentative: (AppleStageMerge.Members, AppleStageMerge.Members)?
    private var automation = false
    private var prepared = false
    private var reserved = false
    private var completed = false
    private var original: NSRunningApplication?
    private var bootInput = [UInt32]()
    private var bootstrap = [[String:Any]]()
    private var timeline = [[String:Any]]()

    private init(_ directory: URL, nonce: UUID, display: String, desktop: UUID, record: String, ordinary: @escaping @MainActor () -> Bool) {
        self.directory = directory; self.nonce = nonce; self.display = display
        self.desktop = desktop; self.record = record; self.ordinary = ordinary
    }
    package static var isRunning: Bool { active != nil }
    static func permitsNativeFocus(_ members: Set<DesktopWindowKey>) -> Bool {
        guard let lab = active, !members.isEmpty, members.count <= 2,
              members.allSatisfy(lab.owns), lab.isolatedScreen() else { return false }
        return true
    }
    static func canDrop(_ source: AppleStageMerge.Members, _ destination: AppleStageMerge.Members) -> Bool {
        guard let lab = active, !lab.attempted, source.count == 1, destination.count == 1,
              let a = source.first, let b = destination.first, a.pid != b.pid,
              lab.owns(a) && lab.owns(b), lab.isolatedScreen() else { return false }
        return true
    }
    static func consume(_ source: AppleStageMerge.Members, _ destination: AppleStageMerge.Members) -> Bool {
        guard let lab = active, canDrop(source, destination) else { return false }
        lab.attempted = true
        lab.tentative = (source,destination)
        return true
    }
    static func permitsLiveWrites() -> Bool {
        guard let lab = active, let (a,b) = lab.tentative,
              a.union(b).allSatisfy(lab.owns), lab.isolatedScreen() else { return false }
        return true
    }
    static func note(_ phase: String, _ sample: AppleStageMerge.Observation) {
        guard let lab = active, lab.attempted, lab.timeline.count < 100 else { return }
        let keys = sample.strip.reduce(sample.current) { $0.union($1) }
        // Record only window identities already independently tied to our direct children.
        guard keys.allSatisfy(lab.owns) else {
            lab.timeline.append(["phase":phase, "observedUnownedWindow":true]); return
        }
        var row: [String:Any] = ["phase":phase, "timeNS":sample.timestamp, "settled":sample.settled,
            "current":sample.current.map(\.number).sorted(), "nativeAXStrip":sample.strip.map { $0.map(\.number).sorted() }]
        if let target = sample.point {
            row["sourceWindow"] = target.window; row["managerTwin"] = target.twin
            row["managerPID"] = target.manager; row["point"] = [target.location.x,target.location.y]
        }
        lab.timeline.append(row)
    }
    static func finish(_ confirmed: Bool) {
        guard let lab = active else { return }
        lab.completed = confirmed
        lab.tentative = nil
        // Stop the fixture session after one drop, including a partial or unknown one.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.terminate(nil)
        }
    }
    /// The explicit, single-use QA CLI can request the native route directly. This
    /// never fabricates a drag nonce, and its receipt cannot prove a physical R4 drag.
    static func nativeQualification(_ groups: [AppleNativeStages.Group],
            run: @escaping @MainActor (AppleNativeStages.Group, AppleNativeStages.Group) async throws -> Void) {
        guard let lab = active, lab.automation, lab.prepared, !lab.reserved, !lab.attempted,
              groups.count == 2, let source = groups.first(where: { !$0.current }),
              let target = groups.first(where: { $0.current }),
              canDrop(Set(source.members),Set(target.members)), fixtureInput() == lab.bootInput else { return }
        lab.reserved = true
        Task { @MainActor in
            guard active === lab, fixtureInput() == lab.bootInput,
                  canDrop(Set(source.members),Set(target.members)) else { NSApp.terminate(nil); return }
            do { try await run(source,target) } catch { NSApp.terminate(nil) }
        }
    }

    private static func fixtureInput() -> [UInt32] {
        NativeSelectionPermit.inputCounters() + [.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged]
            .map { CGEventSource.counterForEventType(.hidSystemState,eventType:$0) }
    }
    private func window(_ child: Child) -> DesktopWindowKey? {
        let app = AXUIElementCreateApplication(child.image.pid)
        AXUIElementSetMessagingTimeout(app,0.06)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,kAXWindowsAttribute as CFString,&raw) == .success,
              let windows = raw as? [AXUIElement], windows.count == 1, let w = windows.first,
              let n = NearpaneOrdinaryWindowRuntime.number(w) else { return nil }
        let key = DesktopWindowKey(pid:child.image.pid,birth:child.image.launch,number:n)
        return owns(key) ? key : nil
    }
    private func seedNativeStages() async {
        let deadline = ContinuousClock.now.advanced(by:.seconds(8))
        while ContinuousClock.now < deadline, Self.active === self,
              Self.fixtureInput() == bootInput, isolatedScreen() {
            if children.count == 2 && children.allSatisfy({ window($0) != nil }) { break }
            try? await Task.sleep(for:.milliseconds(80))
        }
        // Each activation is limited to one exact, signed, freshly observed fixture.
        // Never activate a personal app to prepare a stage.
        for child in children {
            guard Self.active === self, Self.fixtureInput() == bootInput, isolatedScreen(),
                  let key = window(child),
                  let target = NSRunningApplication(processIdentifier:key.pid), !target.isTerminated,
                  [original?.processIdentifier, getpid()].compactMap({$0}).contains(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) ||
                    children.contains(where:{$0.image.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier}) else {
                NSApp.terminate(nil); return
            }
            guard target.activate(options:[]) else { NSApp.terminate(nil); return }
            let bound = ContinuousClock.now.advanced(by:.seconds(3))
            var observations = 0
            while ContinuousClock.now < bound, Self.active === self, isolatedScreen(), Self.fixtureInput() == bootInput {
                let app = AXUIElementCreateApplication(key.pid)
                AXUIElementSetMessagingTimeout(app,0.04)
                var raw: CFTypeRef?
                if target.isActive, owns(key),
                   AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&raw) == .success,
                   let raw, CFGetTypeID(raw) == AXUIElementGetTypeID(),
                   NearpaneOrdinaryWindowRuntime.number(raw as! AXUIElement) == key.number {
                    bootstrap.append(["pid":key.pid,"birth":key.birth,"window":key.number,"timeNS":DispatchTime.now().uptimeNanoseconds])
                    observations += 1
                    if observations == 2 { break }
                } else { observations = 0 }
                try? await Task.sleep(for:.milliseconds(80))
            }
            guard observations == 2 else { NSApp.terminate(nil); return }
        }
        prepared = true
    }
    /// R4 sees live product data for the signed cohort only. If another ordinary
    /// window appears while the reader is away, discard that complete sample.
    @MainActor private struct FixtureProvider: LiveDesktopObservationProvider {
        let base: any DesktopObservationProvider
        var capabilities: DesktopCapabilities { base.capabilities }
        func snapshot() async throws -> DesktopSnapshot { try await snapshot(experimentalSpaces:false) }
        func snapshot(experimentalSpaces: Bool) async throws -> DesktopSnapshot {
            guard let lab = active, lab.isolatedScreen() else { throw AppleStageMerge.Failure.interrupted }
            var sample: DesktopSnapshot
            if let live = base as? any LiveDesktopObservationProvider {
                sample = try await live.snapshot(experimentalSpaces:experimentalSpaces)
            } else { sample = try await base.snapshot() }
            guard active === lab, lab.isolatedScreen() else { throw AppleStageMerge.Failure.interrupted }
            sample.windows = sample.windows.filter { row in
                guard let key = DesktopWindowKey(row) else { return false }
                return lab.owns(key)
            }
            return sample
        }
        func discardVisitedSpaces() { (base as? any LiveDesktopObservationProvider)?.discardVisitedSpaces() }
    }
    package static func observationProvider() -> any DesktopObservationProvider {
        FixtureProvider(base:NativeDesktopProvider.packaged())
    }
    private func owns(_ key: DesktopWindowKey) -> Bool {
        guard OrdinaryDesktopMembership.contains(key.number,display:display,record:record,uuid:desktop),
              let child = children.first(where: { $0.image.pid == key.pid && $0.image.launch == key.birth }),
              child.process.isRunning, (try? OrdinaryProcessImage.read(key.pid)) == child.image,
              (try? OrdinaryProcessImage.signingDigest(key.pid)) == child.signature else { return false }
        var proc = proc_bsdinfo()
        guard proc_pidinfo(key.pid, PROC_PIDTBSDINFO, 0, &proc, Int32(MemoryLayout.size(ofValue: proc))) ==
                MemoryLayout.size(ofValue: proc), proc.pbi_ppid == UInt32(getpid()) else { return false }
        let app = AXUIElementCreateApplication(key.pid)
        AXUIElementSetMessagingTimeout(app, 0.06)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,kAXWindowsAttribute as CFString,&value) == .success,
              let windows = value as? [AXUIElement], windows.count == 1,
              let window = windows.first, NearpaneOrdinaryWindowRuntime.number(window) == key.number else { return false }
        return true
    }
    private func isolatedScreen() -> Bool {
        guard ordinary(), NSScreen.screens.count == 1, StageManagerPreference.read() == true, WindowContentPreview.sessionAvailable(),
              let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return false }
        let system = Set(["com.apple.WindowManager", "com.apple.dock"])
        let owned = Set(children.map { $0.image.pid }).union([getpid()])
        for row in rows {
            guard let layer = row[kCGWindowLayer as String] as? Int32 else { return false }
            guard layer == 0 else { continue }
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32 else { return false }
            if owned.contains(pid) { continue }
            // A Finder file window, including one in another stage, is personal.
            guard let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier,
                  system.contains(id), let url = app.bundleURL,
                  url.resolvingSymlinksInPath().path.hasPrefix("/System/Library/") else { return false }
        }
        return true
    }

    package static func start(_ nonce: UUID, automate: Bool, display: String, desktop: UUID, record: String,
                              ordinary: @escaping @MainActor () -> Bool) throws {
        guard active == nil, getuid() == geteuid(), getuid() != 0, StageManagerPreference.read() == true,
              AXIsProcessTrusted(), CGPreflightListenEventAccess(), CGPreflightPostEventAccess(),
              Bundle.main.bundleIdentifier == "com.holdsnow.nearpane.host",
              Bundle.main.object(forInfoDictionaryKey: "NearpaneReadOnlyGuardianProtocol") == nil,
              Bundle.main.object(forInfoDictionaryKey: "NearpaneNativeMergeFixtureProtocol") as? Int == 1,
              Bundle.main.object(forInfoDictionaryKey: "NearpaneNativeMergeNonce") as? String == nonce.uuidString.lowercased()
        else { throw AppleStageMerge.Failure.unavailable }
        let root = URL(fileURLWithPath: "/private/tmp/nearpane-apple-merge." + nonce.uuidString.lowercased(), isDirectory: true)
        var st = stat()
        guard lstat(root.path,&st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFDIR, st.st_mode & 0o777 == 0o700,
              root == root.resolvingSymlinksInPath(), root.appendingPathComponent("Nearpane.app", isDirectory:true) == Bundle.main.bundleURL.resolvingSymlinksInPath(),
              try validate(Bundle.main.bundleURL, id: "com.holdsnow.nearpane.host") == OrdinaryProcessImage.signingDigest(getpid()),
              let origin = NSWorkspace.shared.frontmostApplication,
              ["com.apple.finder","com.holdsnow.nearpane.host"].contains(origin.bundleIdentifier ?? "")
        else { throw AppleStageMerge.Failure.unavailable }
        let lab = AppleStageMergeFixture(root, nonce: nonce, display:display,desktop:desktop,record:record,ordinary:ordinary)
        guard lab.isolatedScreen(), !FileManager.default.fileExists(atPath: root.appendingPathComponent("run.json").path) else {
            throw AppleStageMerge.Failure.unavailable
        }
        // Atomically consume the signed session nonce before any fixture process is launched.
        try Data("{\"started\":true}\n".utf8).write(to: root.appendingPathComponent("run.json"), options:.withoutOverwriting)
        lab.original = origin; lab.automation = automate; lab.bootInput = fixtureInput()
        active = lab
        do {
            for name in ["A","B"] {
                let id = "com.holdsnow.stageworkset-merge-fixture." + name.lowercased()
                let app = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Merge " + name + ".app",isDirectory:true)
                let signature = try validate(app,id:id)
                let path = app.appendingPathComponent("Contents/MacOS/MergeFixture")
                guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
                      path.path == path.resolvingSymlinksInPath().path else { throw AppleStageMerge.Failure.unavailable }
                let process = Process()
                process.executableURL = path
                process.arguments = [nonce.uuidString.lowercased()]
                try process.run()
                // The child independently exits on parent death or its bounded deadline.
                let image = try OrdinaryProcessImage.read(process.processIdentifier)
                guard image.executable == path, try OrdinaryProcessImage.signingDigest(image.pid) == signature else {
                    throw AppleStageMerge.Failure.unavailable
                }
                lab.children.append(Child(process:process,image:image,signature:signature,identifier:id))
            }
        } catch { stop(); throw error }
        if automate { Task { @MainActor in await lab.seedNativeStages() } }
        Task { @MainActor in
            let end = ContinuousClock.now.advanced(by:.seconds(120))
            while active === lab, ContinuousClock.now < end, lab.isolatedScreen() {
                try? await Task.sleep(for:.milliseconds(200))
            }
            if active === lab { NSApp.terminate(nil) }
        }
    }

    private static func validate(_ app: URL, id: String) throws -> Data {
        let text = "anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var requirement: SecRequirement?, code: SecStaticCode?, signed: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        guard app.path == app.resolvingSymlinksInPath().path, Bundle(url:app)?.bundleIdentifier == id,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, .init(rawValue:kSecCSSigningInformation), &signed) == errSecSuccess,
              let hash = (signed as? [String:Any])?[kSecCodeInfoUnique as String] as? Data, hash.count >= 20 else {
            throw AppleStageMerge.Failure.unavailable
        }
        return hash
    }
    package static func stop() {
        guard let lab = active else { return }
        active = nil
        // Only an unchanged, registered fixture process receives a normal quit request.
        for child in lab.children where child.process.isRunning && (try? OrdinaryProcessImage.read(child.image.pid)) == child.image {
            _ = NSRunningApplication(processIdentifier:child.image.pid)?.terminate()
        }
        let receipt: [String:Any] = ["timeline":lab.timeline,"bootstrap":lab.bootstrap,
            "nativeFixtureAutomation":lab.automation,"physicalR4Gesture":"NOT_RUN","protocol":1,"nonce":lab.nonce.uuidString.lowercased(),
            "attempted":lab.attempted,"membershipDoubleRead":lab.completed,"productionQualified":false,
            "children":lab.children.map { ["pid":$0.image.pid,"birth":$0.image.launch,
                "cdhash":$0.signature.map { String(format:"%02x",$0) }.joined(),"identifier":$0.identifier] as [String:Any] }]
        if let data = try? JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys]) {
            try? data.write(to:lab.directory.appendingPathComponent("host.json"),options:.withoutOverwriting)
        }
    }
}
#else
import NearpaneCore
@MainActor package enum AppleStageMergeFixture {
    package static func observationProvider() -> any DesktopObservationProvider { UnavailableDesktopProvider() }
    static func nativeQualification(_ groups: [AppleNativeStages.Group], run: @escaping @MainActor (AppleNativeStages.Group, AppleNativeStages.Group) async throws -> Void) {}
    package static var isRunning: Bool { false }
    static func permitsNativeFocus(_ members: Set<DesktopWindowKey>) -> Bool { false }
    static func canDrop(_ source: Set<DesktopWindowKey>, _ destination: Set<DesktopWindowKey>) -> Bool { false }
}
#endif
