import AppKit
import RiftletCore
import RiftletAdapters

/// Created once by browser-before for a single disposable draft and media file.
struct TestTargetBinding: Codable, Equatable, Sendable {
    let session, process, window, tab, url, nonce, assetID, sha256: String
    let timeOrigin, boundAt, expiresAt: Double

    func check(session expected: String, now: Double) throws {
        guard session == expected, UUID(uuidString: session)?.uuidString.lowercased() == session,
              UUID(uuidString: nonce)?.uuidString.lowercased() == nonce,
              UUID(uuidString: assetID)?.uuidString.lowercased() == assetID,
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              process.range(of: #"^chrome-kernel-v1:[1-9][0-9]*:[0-9]+:[0-9]+$"#, options: .regularExpression) != nil,
              Int64(window).map({ $0 > 0 }) == true, Int64(tab).map({ $0 > 0 }) == true,
              url.range(of: #"^https://chatgpt\.com/c/[A-Za-z0-9-]+$"#, options: .regularExpression) != nil,
              timeOrigin > 0, boundAt <= now, now <= expiresAt, expiresAt - boundAt <= 900 else {
            throw WebAdapterError.invalidTarget
        }
    }
    @MainActor func requireSelectedRoute() throws {
        let parts = process.split(separator: ":")
        guard parts.count == 4, let pid = Int32(parts[1]), ChromeProcessIdentity.read(pid: pid)?.session == process,
              try AcceptanceBrowserRoute(pid: pid, window: window, tab: tab).selected() else { throw WebAdapterError.invalidTarget }
    }
    func accepts(_ target: TargetLease) -> Bool {
        target.adapterID == "chatgpt-web" && target.surface == .webChat && target.applicationID == "com.google.Chrome" &&
        target.sessionID == process && target.windowID == window && target.tabID == tab &&
        !target.documentID.isEmpty && !target.composerID.isEmpty && !target.draftGeneration.isEmpty
    }

    func program(_ original: WebPageProgram, guardSource: String) throws -> WebPageProgram {
        // Fail closed on a changed upstream input implementation, including duplicated anchors.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(self), as: UTF8.self)
        var source = original.functionSource
        let entry = "  const KEY = '__riftletIndependentFileInput20261104';"
        let chosen = "    const parts = composer();"
        let setter = "      Reflect.apply(setter, input, [transfer.files]);"
        guard !guardSource.isEmpty, source.components(separatedBy: entry).count == 2,
              source.components(separatedBy: chosen).count == 2, source.components(separatedBy: setter).count == 2 else { throw WebAdapterError.programUnavailable }
        let gate = "const nearpaneCheck = (handoff, parts) => (" + guardSource + ")(" + json + ",command,native,handoff,parts);"
        source = source.replacingOccurrences(of: entry, with: gate + "\nif (!['observe','discard'].includes(command.action)) nearpaneCheck(false);\n" + entry)
        source = source.replacingOccurrences(of: chosen, with: chosen + "\n    nearpaneCheck(false, parts);")
        source = source.replacingOccurrences(of: setter, with: "      nearpaneCheck(true, op.binding);\n" + setter)
        return WebPageProgram(sourceID: original.sourceID, functionSource: source,
                              maximumChunkBytes: original.maximumChunkBytes, inputDiscoveryTimeout: original.inputDiscoveryTimeout)
    }
}

struct TestInputClaim: Codable {
    let session, nonce: String
    let invocationID: UUID
    let claimedAt: Double
    let identity: ObservationIdentity
    func permitsObservation(_ observed: ObservationIdentity?, binding: TestTargetBinding) -> Bool {
        session == binding.session && nonce == binding.nonce && observed == identity
            && binding.accepts(identity.target) && identity.assetID.uuidString.lowercased() == binding.assetID
            && identity.assetSHA256 == binding.sha256 && identity.attempt == 1
    }
}

/// Ordinary product clicks use ChromeAppleEventsExecutor directly. This wrapper is installed only for a marked fixture.
@MainActor final class BoundTestExecutor: WebClickTargetPinning {
    let directory: URL
    private let base: any WebClickTargetPinning
    private let guardSource: String
    private var bound: TestTargetBinding?
    private var pinned: TargetLease?
    init(directory: URL, base: any WebClickTargetPinning, guardSource: String) {
        self.directory = directory; self.base = base; self.guardSource = guardSource
    }
    private func binding() throws -> TestTargetBinding {
        let file = directory.appendingPathComponent("target-binding.json")
        guard file.resolvingSymlinksInPath().path == file.path else { throw WebAdapterError.invalidTarget }
        let value = try JSONDecoder().decode(TestTargetBinding.self, from: Data(contentsOf: file))
        try value.check(session: directory.lastPathComponent, now: Date().timeIntervalSince1970)
        guard bound == nil || bound == value else { throw WebAdapterError.invalidTarget }
        bound = value
        return value
    }
    var hasClaim: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("input-claim.json").path) }
    func checkAsset(_ image: ImportedAsset) throws {
        let b = try binding()
        guard image.id.uuidString.lowercased() == b.assetID, image.sha256 == b.sha256,
              !hasClaim else {
            throw WebAdapterError.invalidRequest
        }
    }
    func targetForClick(program: WebPageProgram) throws -> Task<TargetLease, Error> {
        let b = try binding()
        try b.requireSelectedRoute()
        let task = try base.targetForClick(program: b.program(program, guardSource: guardSource))
        return Task {
            let target = try await task.value
            try Task.checkCancellation()
            guard try binding() == b, b.accepts(target), pinned == nil || pinned == target else { throw WebAdapterError.invalidTarget }
            pinned = target
            return target
        }
    }
    func execute(_ command: WebBridgeCommand, program: WebPageProgram) async throws -> Data {
        let b = try binding()
        guard let target = command.target, b.accepts(target) else { throw WebAdapterError.invalidTarget }
        if command.action == .observe, hasClaim {
            let file = directory.appendingPathComponent("input-claim.json")
            guard file.resolvingSymlinksInPath().path == file.path,
                  try JSONDecoder().decode(TestInputClaim.self, from: Data(contentsOf: file)).permitsObservation(command.identity, binding: b)
            else { throw WebAdapterError.invalidTarget }
        } else {
            guard target == pinned else { throw WebAdapterError.invalidTarget }
            if hasClaim && [.begin,.chunk,.commit].contains(command.action) { throw WebAdapterError.invalidRequest }
        }
        if let id = command.identity {
            guard id.target == target, id.assetID.uuidString.lowercased() == b.assetID, id.assetSHA256 == b.sha256, id.attempt == 1
            else { throw WebAdapterError.invalidRequest }
        }
        let guarded = try b.program(program, guardSource: guardSource)
        if [.begin,.commit].contains(command.action) { try b.requireSelectedRoute() }
        if command.action == .commit {
            guard let id = command.identity, let invocation = command.invocationID else { throw WebAdapterError.invalidRequest }
            // Persist once, before submission, even if Chrome's reply is lost. No second commit on reconnect.
            let evidence = TestInputClaim(session: b.session, nonce: b.nonce, invocationID: invocation,
                                          claimedAt: Date().timeIntervalSince1970, identity: id)
            try JSONEncoder().encode(evidence).write(to: directory.appendingPathComponent("input-claim.json"), options: .withoutOverwriting)
        }
        return try await base.execute(command, program: guarded)
    }
}
