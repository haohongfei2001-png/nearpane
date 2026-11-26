import AppKit
import CReadOnlySpaces
import Security
import NearpaneCore

/// This route has no command-line or IPC entrance. A fixture, helper or differently signed
/// executable cannot use it to issue a Stage command under the installed Host's identity.
@MainActor package final class StageHostAccess {
    static let app = "/Applications/Nearpane.app"
    static let executable = app + "/Contents/MacOS/NearpaneHost"
    private let image: OrdinaryProcessImage, digest: String

    static func matches(bundle: String?, root: String, executable: String, expected: String, actual: String) -> Bool {
        let installed = bundle == "com.holdsnow.nearpane.alpha" && root == app && executable == Self.executable
        let candidate = IndependentStagePolicy.candidateRequested && bundle == IndependentStagePolicy.candidateBundleID &&
            executable == root + "/Contents/MacOS/NearpaneHost"
        return (installed || candidate) && expected.count == 40 && expected.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && actual == expected
    }

    nonisolated private static func signing() throws -> String {
        try OrdinaryProcessImage.signingDigest(getpid()).map { String(format: "%02x", $0) }.joined()
    }

    package init(expectedCDHash: String) throws {
        let before = try OrdinaryProcessImage.read(getpid()), digest = try Self.signing()
        guard Self.matches(bundle: Bundle.main.bundleIdentifier, root: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
                  executable: before.executable.path, expected: expectedCDHash, actual: digest),
              try OrdinaryProcessImage.read(getpid()) == before, AXIsProcessTrusted() else { throw StageSwitchError.unavailable }
        self.image = before; self.digest = digest
    }

    private static let signedDirectoryReader: Bool = {
        let clause = #"anchor apple generic and identifier "com.holdsnow.nearpane.alpha" and certificate leaf[subject.OU] = "ZB9D4T66QB" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
        var code: SecCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(clause as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }()

    /// Expose only a read closure. Possessing the canonical Host's AX permission cannot mint a writer.
    package static func directoryReader() throws -> @Sendable (NativeSpaceWindow, OrdinaryDesktopIdentity) throws -> StageWindowPhysicalObservation? {
        guard signedDirectoryReader || IndependentStagePolicy.candidateRequested else { throw StageSwitchError.unavailable }
        let access = try StageHostAccess(expectedCDHash: signing())
        return { window, home in try access.currentSurface(window, home: home) }
    }

    /// A new Host may only retire its old bookkeeping after the former worker
    /// ended. These are fresh read-only AX bindings, never a continuation of the
    /// old lifetime and never a source of focus, geometry or visibility writes.
    package static func confirmsColdSpacesReturn(_ returned: [StageWindowReturn], hiddenSpaces: [UInt64]) async -> Bool {
        guard returned.count <= 64, Set(returned.map { $0.original.window }).count == returned.count,
              let access = try? StageHostAccess(expectedCDHash: signing()) else { return false }
        var retained = [NativeSpaceWindow: (owner: OrdinaryOwnerIdentity, bundle: String, element: AXUIElement)]()
        var absent = Set<NativeSpaceWindow>()

        func sample() throws -> Bool {
            try access.check()
            guard StageWindowPhysicalReader.hiddenSpacesReleased(hiddenSpaces) else { return false }
            for item in returned {
                let key = item.original.window
                let presence = NPReadWindowNumberPresence(key.number)
                if presence == 0 {
                    guard retained[key] == nil else { return false }
                    if let image = try? OrdinaryProcessImage.read(key.pid) {
                        if image.launch == key.birth {
                            guard let bundle = NSRunningApplication(processIdentifier: key.pid)?.bundleIdentifier else { return false }
                            let owner = OrdinaryOwnerIdentity()
                            try checkOwner(owner, pid: key.pid, launch: key.birth, bundle: bundle)
                            let list = try windows(key.pid), numbers = list.compactMap(number)
                            guard numbers.count == list.count, !numbers.contains(key.number) else { return false }
                            try checkOwner(owner, pid: key.pid, launch: key.birth, bundle: bundle)
                        }
                    } else {
                        guard kill(key.pid, 0) == -1, errno == ESRCH else { return false }
                    }
                    guard NPReadWindowNumberPresence(key.number) == 0 else { return false }
                    absent.insert(key)
                    continue
                }
                guard presence == 1, !absent.contains(key) else { return false }
                let (owner, bundle, element) = try original(key)
                guard try role(element) else { return false }
                if let previous = retained[key] {
                    try checkOwner(previous.owner, pid: key.pid, launch: key.birth, bundle: previous.bundle)
                    guard previous.bundle == bundle, CFEqual(previous.element, element) else { return false }
                } else { retained[key] = (owner, bundle, element) }
                let home = OrdinaryDesktopIdentity(display: item.scope.display.uuidString,
                    record: String(item.nativeID), uuid: item.scope.nativeSpace)
                let id = ManagedWindowID(pid: key.pid, launch: key.birth, number: key.number, element: UUID())
                guard try StageWindowPhysicalReader.returnedHome(id, original: element, home: home,
                    frame: item.original.frame, allowMinimized: item.original.visibility == .minimized) else { return false }
                try checkOwner(owner, pid: key.pid, launch: key.birth, bundle: bundle)
            }
            try access.check()
            return StageWindowPhysicalReader.hiddenSpacesReleased(hiddenSpaces)
        }
        do {
            guard try sample() else { return false }
            try await Task.sleep(for: .milliseconds(100))
            return try sample()
        } catch { return false }
    }

    nonisolated func check() throws {
        guard AXIsProcessTrusted(), try OrdinaryProcessImage.read(getpid()) == image,
              try Self.signing() == digest, !StageManagerPreference.ownsWindowDispatch else { throw StageSwitchError.unavailable }
    }

    /// Read only the returned exact PID/window identity. The complete current-Space candidate
    /// roster and its two membership samples come independently from the signed desktop reader.
    nonisolated package func role(of window: NativeSpaceWindow) throws -> Bool {
        try check()
        let (owner, bundle, element) = try Self.original(window)
        let measured = try Self.role(element)
        try checkOwner(owner, pid: window.pid, launch: window.birth, bundle: bundle)
        guard number(element) == window.number else { throw StageSwitchError.ownership }
        return measured
    }

    // All AX objects and the mutable owner witness are local to this read. Only
    // the immutable physical observation leaves it; this cannot mint a writer.
    nonisolated package func currentSurface(_ window: NativeSpaceWindow, home: OrdinaryDesktopIdentity) throws -> StageWindowPhysicalObservation? {
        try check()
        let (owner, bundle, element) = try Self.original(window)
        let standard = try Self.role(element)
        try checkOwner(owner, pid: window.pid, launch: window.birth, bundle: bundle)
        guard number(element) == window.number else { throw StageSwitchError.ownership }
        guard standard else { return nil }
        let id = ManagedWindowID(pid: window.pid, launch: window.birth, number: window.number, element: UUID())
        let observation = try StageWindowPhysicalReader.read(id, original: element, home: home)
        try checkOwner(owner, pid: window.pid, launch: window.birth, bundle: bundle)
        guard observation.membership == UInt64(home.record) else { throw StageSwitchError.ownership }
        if observation.onscreen, !observation.minimized {
            guard try displayID(observation.frame).caseInsensitiveCompare(home.display) == .orderedSame else {
                throw StageSwitchError.ownership
            }
        }
        return observation
    }

    nonisolated fileprivate static func role(_ element: AXUIElement) throws -> Bool {
        guard let role = attribute(element, kAXRoleAttribute) as? String else { throw StageSwitchError.incomplete }
        guard role == kAXWindowRole else { return false }
        guard let subrole = attribute(element, kAXSubroleAttribute) as? String else { throw StageSwitchError.incomplete }
        guard subrole == kAXStandardWindowSubrole else { return false }
        guard let modal = attribute(element, kAXModalAttribute) as? Bool,
              let full = attribute(element, "AXFullScreen") as? Bool else { throw StageSwitchError.incomplete }
        return !modal && !full
    }

    nonisolated fileprivate static func original(_ window: NativeSpaceWindow) throws -> (OrdinaryOwnerIdentity, String, AXUIElement) {
        guard let app = NSRunningApplication(processIdentifier: window.pid), let bundle = app.bundleIdentifier else {
            throw StageSwitchError.ownership
        }
        let owner = OrdinaryOwnerIdentity()
        try checkOwner(owner, pid: window.pid, launch: window.birth, bundle: bundle)
        let found = try windows(window.pid).filter { number($0) == window.number }
        guard found.count == 1, let element = found.first else { throw StageSwitchError.incomplete }
        try checkOwner(owner, pid: window.pid, launch: window.birth, bundle: bundle)
        return (owner, bundle, element)
    }
}

/// Only this immutable AX receiver crosses the executor boundary. Its timeout
/// was fixed during the original bind. The owning StageHostWindow excludes all
/// other reads/writes of that receiver while a background read is outstanding;
/// its mutable monitor, observer and owner witness never enter this wrapper.
private struct StageOriginalAXReceiver: @unchecked Sendable {
    let element: AXUIElement
}

private actor StageHostPhysicalReader {
    private let original: StageOriginalAXReceiver
    init(_ original: StageOriginalAXReceiver) { self.original = original }
    func read(_ id: ManagedWindowID, home: OrdinaryDesktopIdentity) throws -> StageWindowPhysicalObservation {
        try Task.checkCancellation()
        return try StageWindowPhysicalReader.read(id, original: original.element, home: home, retainedStandardWindow: true)
    }
}

private struct StagePreparedHostWindow: Sendable {
    let id: ManagedWindowID, original: StageOriginalAXReceiver, bundle: String
    let image: OrdinaryProcessImage, digest: Data
    let observation: StageWindowPhysicalObservation
}

@MainActor package final class StageHostWindow {
    package let id: ManagedWindowID
    private let access: StageHostAccess, owner: OrdinaryOwnerIdentity, bundle: String, monitor: WindowMonitor
    private let home: OrdinaryDesktopIdentity, engine: StageEngineOwner, lifetime: UUID?
    private var creation: CreatedWindowWatch?
    private var spent = Set<UUID>()
    private let physicalReader: StageHostPhysicalReader
    private enum AccessPhase { case idle, reading, writing }
    private var accessPhase: AccessPhase = .idle

    struct PrimitiveFence {
        let deadline: TimeInterval, originalInput: [UInt32]
        private(set) var steps = 0
        init(now: TimeInterval, input: [UInt32]) { deadline = now + 5; originalInput = input }
        func check(now: TimeInterval, input: [UInt32], current: Bool) throws {
            guard current, now < deadline, !originalInput.isEmpty, input == originalInput, steps < 8 else {
                throw StageSwitchError.interrupted
            }
        }
        mutating func next() { steps += 1 }
    }

    static func matches(_ command: StageWindowCommand, id: ManagedWindowID, lifetime: UUID?,
                        home: OrdinaryDesktopIdentity, owner: StageEngineOwner) -> Bool {
        guard let lifetime, let record = UInt64(home.record), record > 0, command.before.lifetime == lifetime,
              !command.restoring, command.generation == owner.generation,
              command.before.window == .init(pid: id.pid, birth: id.launch, number: id.number), command.before.visibility == .visible,
              command.scope.display == UUID(uuidString: home.display), command.scope.nativeSpace == home.uuid,
              command.nativeID == record else { return false }
        switch command.action { case .focus, .place: return true; default: return false }
    }

    package static func bind(_ window: NativeSpaceWindow, lifetime: UUID, home: OrdinaryDesktopIdentity,
                             engine: StageEngineOwner, access: StageHostAccess) async throws -> StageHostWindow {
        try access.check()
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try access.check()
            let image = try OrdinaryProcessImage.read(window.pid), digest = try OrdinaryProcessImage.signingDigest(window.pid)
            let (owner, bundle, element) = try StageHostAccess.original(window)
            guard try StageHostAccess.role(element) else { throw StageSwitchError.ownership }
            let id = ManagedWindowID(pid: window.pid, launch: window.birth, number: window.number, element: UUID())
            let observed = try StageWindowPhysicalReader.read(id, original: element, home: home, retainedStandardWindow: true)
            try checkOwner(owner, pid: window.pid, launch: window.birth, bundle: bundle)
            guard try OrdinaryProcessImage.read(window.pid) == image,
                  try OrdinaryProcessImage.signingDigest(window.pid) == digest else { throw StageSwitchError.ownership }
            try access.check()
            return StagePreparedHostWindow(id: id, original: .init(element: element), bundle: bundle,
                image: image, digest: digest, observation: observed)
        }.value
        guard !Task.isCancelled, prepared.id.pid == window.pid, prepared.id.launch == window.birth,
              prepared.id.number == window.number, prepared.observation.id == prepared.id,
              prepared.observation.membership == UInt64(home.record) else { throw StageSwitchError.interrupted }
        try access.check()
        // The mutable owner witness is created on the owning UI actor. The
        // prepared original AX object is installed directly, never looked up
        // again by its number after the executor handoff.
        let owner = OrdinaryOwnerIdentity()
        try checkOwner(owner, pid: window.pid, launch: window.birth, bundle: prepared.bundle)
        guard try OrdinaryProcessImage.read(window.pid) == prepared.image,
              try OrdinaryProcessImage.signingDigest(window.pid) == prepared.digest else { throw StageSwitchError.ownership }
        return StageHostWindow(id: prepared.id, original: prepared.original.element, bundle: prepared.bundle,
            owner: owner, lifetime: lifetime, home: home, engine: engine, access: access)
    }

    private init(id: ManagedWindowID, original: AXUIElement, bundle: String, owner: OrdinaryOwnerIdentity,
                 lifetime: UUID?, home: OrdinaryDesktopIdentity, engine: StageEngineOwner, access: StageHostAccess) {
        self.id = id; self.bundle = bundle; self.owner = owner; self.lifetime = lifetime
        self.home = home; self.engine = engine; self.access = access
        monitor = WindowMonitor(id: id, bundle: bundle, element: original, parent: getppid(), owner: owner, signalParent: false)
        physicalReader = StageHostPhysicalReader(.init(element: original))
    }

    package func observation(home: OrdinaryDesktopIdentity) throws -> StageWindowPhysicalObservation {
        guard accessPhase != .reading else { throw StageSwitchError.interrupted }
        try access.check()
        guard self.home == home, monitor.canListAgain else { throw StageSwitchError.ownership }
        try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
        let sample = try StageWindowPhysicalReader.read(id, original: monitor.element, home: home, retainedStandardWindow: true)
        try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
        return sample
    }

    /// Keep native AX/CG/Space IPC off the UI executor without sharing mutable
    /// observer or process-binding state. The same original AX receiver is used
    /// for every read, including while its owner's AXWindows list is empty.
    package func observationAsync(home: OrdinaryDesktopIdentity) async throws -> StageWindowPhysicalObservation {
        guard !Task.isCancelled, accessPhase == .idle, self.home == home, monitor.canListAgain else {
            throw StageSwitchError.interrupted
        }
        try access.check()
        try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
        accessPhase = .reading
        defer { accessPhase = .idle }
        let sample = try await physicalReader.read(id, home: home)
        guard !Task.isCancelled, accessPhase == .reading, self.home == home, monitor.canListAgain else {
            throw StageSwitchError.interrupted
        }
        try access.check()
        try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
        return sample
    }

    package func departure() throws -> StageWindowDeparture? {
        guard accessPhase == .idle else { throw StageSwitchError.interrupted }
        try access.check()
        guard let lifetime else { return nil }
        return StageWindowDeparture.confirmed(try monitor.stageClosure(), original: id, lifetime: lifetime)
    }

    /// After the Spaces engine releases its leases, independently confirm the exact bound
    /// window's return even if a desktop gesture or native overview has changed what is current.
    /// An absent/invalid AX element is not a successful return; departure() supplies separate
    /// positive closure evidence. A failed yellow-button transaction may retain native minimization.
    package func returnedHome(home: OrdinaryDesktopIdentity, frame: SurfaceRect, allowMinimized: Bool = false) -> Bool {
        do {
            guard accessPhase == .idle else { return false }
            try access.check()
            guard self.home == home, lifetime != nil, monitor.canListAgain else { return false }
            try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
            let returned = try StageWindowPhysicalReader.returnedHome(id, original: monitor.element, home: home,
                frame: frame, allowMinimized: allowMinimized, retainedStandardWindow: true)
            try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
            try access.check()
            return returned
        } catch { return false }
    }

    package func beginCreation(_ token: UUID) throws {
        guard accessPhase == .idle else { throw StageSwitchError.interrupted }
        let observed = try observation(home: home)
        guard lifetime != nil, observed.onscreen, !observed.minimized, observed.membership == UInt64(home.record),
              observed.focus == .init(pid: id.pid, birth: id.launch, number: id.number) else { throw StageSwitchError.ownership }
        creation = try CreatedWindowWatch(anchor: id, grant: token, focusedOriginal: monitor.element, stageHome: home)
    }

    package func endCreation(_ token: UUID) { if creation?.grant == token { creation = nil } }

    package func nextCreation(_ token: UUID) throws -> StageHostWindow? {
        guard accessPhase == .idle else { throw StageSwitchError.interrupted }
        try access.check()
        try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
        guard let creation, creation.grant == token, creation.anchor == id, monitor.canListAgain else { throw StageSwitchError.ownership }
        guard let (original, n) = try creation.take() else { return nil }
        let child = StageHostWindow(id: .init(pid: id.pid, launch: id.launch, number: n, element: UUID()),
            original: original, bundle: bundle, owner: owner, lifetime: nil, home: home, engine: engine, access: access)
        let sample = try child.observation(home: home)
        guard sample.onscreen, !sample.minimized, sample.membership == UInt64(home.record) else { throw StageSwitchError.ownership }
        return child
    }

    /// Limits are identical for placement and focus. Every AX primitive rechecks the original
    /// intent and actual HID counters immediately before the existing physical verification.
    package func perform(_ command: StageWindowCommand, scope: OrdinaryFocusScope, current: @escaping @MainActor () -> Bool) throws {
        guard accessPhase == .idle else { throw StageSwitchError.interrupted }
        accessPhase = .writing
        defer { accessPhase = .idle }
        let window = NativeSpaceWindow(pid: id.pid, birth: id.launch, number: id.number)
        guard Self.matches(command, id: id, lifetime: lifetime, home: home, owner: engine), scope.desktop == home,
              current() else { throw StageSwitchError.ownership }
        try access.check()
        var fence = PrimitiveFence(now: ProcessInfo.processInfo.systemUptime, input: WindowSelectionInput.counters())
        let deadline = fence.deadline
        func permit() throws {
            try access.check()
            try fence.check(now: ProcessInfo.processInfo.systemUptime, input: WindowSelectionInput.counters(), current: current())
        }
        let first = try observation(home: home)
        guard first.onscreen, !first.minimized, first.id == id, first.membership == command.nativeID,
              first.frame == command.before.frame, spent.insert(command.intent).inserted else { throw StageSwitchError.ownership }
        try permit()
        switch command.action {
        case .focus:
            try focusCurrentWindow(id: id, element: monitor.element, owner: owner, bundle: bundle, frame: first.frame,
                                   display: home.display, deadline: deadline, space: home.record, scope: scope, windowlessHelper: false) {
                try permit(); fence.next()
            }
        case .place(let target):
            try monitor.bindDesktop(home)
            let proof = try monitor.prepare()
            guard proof.first.cgFrame == first.frame, proof.second.cgFrame == first.frame else { throw StageSwitchError.interrupted }
            try permit()
            let landed = try monitor.write(from: first.frame, to: target, placement: nil, retainedPeer: nil,
                                          stageDeadline: deadline, stagePermit: { try permit(); fence.next() }, confirmedStep: { _ in })
            guard landed.first.id == id, landed.second.id == id, landed.first.cgFrame == target, landed.second.cgFrame == target
            else { throw StageSwitchError.incomplete }
        default: throw StageSwitchError.ownership
        }
        let last = try observation(home: home)
        guard current(), ProcessInfo.processInfo.systemUptime < deadline, WindowSelectionInput.counters() == fence.originalInput,
              last.id == id, last.onscreen, !last.minimized,
              last.membership == command.nativeID else { throw StageSwitchError.interrupted }
        switch command.action {
        case .focus: guard last.focus == window else { throw StageSwitchError.incomplete }
        case .place(let target): guard last.frame == target else { throw StageSwitchError.incomplete }
        default: throw StageSwitchError.ownership
        }
    }
}
