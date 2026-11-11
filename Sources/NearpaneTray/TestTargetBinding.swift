import AppKit
import CryptoKit
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(self), as: UTF8.self)
        return try GuardedDraftProgram.compose(original, guardSource: guardSource, binding: json)
    }
}

enum GuardedDraftProgram {
    static func compose(_ original: WebPageProgram, guardSource: String, binding: String, product: Bool = false) throws -> WebPageProgram {
        // The digest covers *all* paths in the reviewed source, including future unanchored side effects.
        let digest = SHA256.hash(data: Data(original.functionSource.utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest == "0daf3f2763e340503b8c957c4ef35a619417c5e486ac48fccbcae3f657ff9a09",
              !guardSource.isEmpty else { throw WebAdapterError.programUnavailable }
        var source = original.functionSource
        func replace(_ anchor: String, _ replacement: String) throws {
            guard source.components(separatedBy: anchor).count == 2 else { throw WebAdapterError.programUnavailable }
            source = source.replacingOccurrences(of: anchor, with: replacement)
        }

        let entry = "  const KEY = '__riftletIndependentFileInput20261104';"
        let gate = "const nearpaneDraft = " + binding + "; const nearpaneCheck = (...args) => (" + guardSource + ")(nearpaneDraft,command,native,...args);"
        if product {
            // A newly pressed thumbnail gets its own lease even in the very same composer.
            try replace("registry.current.editor !== parts.editor)", "registry.current.editor !== parts.editor || registry.current.target.clickBindingID !== nearpaneDraft.nonce.toUpperCase())")
            try replace("draftGeneration: crypto.randomUUID()", "draftGeneration: crypto.randomUUID(), clickBindingID: nearpaneDraft.nonce.toUpperCase()")
        }
        let chosen = "    const parts = composer();"
        try replace(chosen, chosen + "\n    nearpaneCheck(false, parts);")

        let prepare = "  let file, transfer, setter;"
        try replace(prepare, """
          const receiver = nearpaneCheck(true, op.binding, () => op.discoveryDeadline,
            (input, own) => !usableInput(input) || otherOwner(input, op.binding, own));
        """ + "\n" + prepare)
        try replace("const run = () => {", "const run = () => receiver.monitor(() => {")
        try replace("return discoverThroughEntry(op, entries, execute, retire);\n  };",
                    "return discoverThroughEntry(op, entries, execute, retire);\n  });")
        try replace("const entries = entryControls(op.binding);", "const entries = receiver.bind(entryControls(op.binding));")
        try replace("entries = entryControls(binding);", "entries = receiver.entries(entryControls(binding));")
        let activate = "const activated = await activate(next);"
        let refused = "return retire('targetInvalidBeforeInput', 'picker', 'targetChanged');"
        try replace(activate, "if (!receiver.activate(next)) " + refused + "\n          " + activate)
        try replace("try { return callback(control); }", "try { return receiver.fire(control, callback); }")
        let owned = "const owned = insideControl ||"
        try replace(owned, "if (!receiver.capture(input)) return false;\n      " + owned)
        let fallback = "if (!intercept(this, method)) return Reflect.apply(original, this, args);"
        try replace(fallback, """
                if (!intercept(this, method)) {
                  if (this.type === 'file') { receiver.refuse(); return; }
                  return Reflect.apply(original, this, args);
                }
        """)
        try replace("if (!event.defaultPrevented && capture(node, 'event')) event.preventDefault();",
                    "if (!event.defaultPrevented) { if (!capture(node, 'event')) receiver.refuse(); event.preventDefault(); }")
        let ended = "const ended = Date.now() >= deadline;"
        try replace(ended, "if (receiver.denied) " + refused + "\n        " + ended)
        let confirm = "op.binding.input = input;"
        try replace(confirm, "if (!receiver.choose(input, invoked)) " + refused + "\n    " + confirm)
        let count = "op.inputCount = 1; op.inputSequence = tick(); op.inputTime = performance.now();"
        // Only internal bookkeeping separates this last proof from the native setter. If it fails,
        // the domain still reports zero inputs. Once entered, a rejected event must remain UNKNOWN.
        try replace(count, "const inputTime = performance.now();\n      if (!receiver.ready(input)) " + refused +
                    "\n      op.inputCount = 1; op.inputSequence = tick(); op.inputTime = inputTime;")
        for effect in ["input.dispatchEvent(new Event('input', {bubbles: true, composed: true}));",
                       "input.dispatchEvent(new Event('change', {bubbles: true}));"] {
            try replace(effect, "receiver.require(input);\n      " + effect)
        }
        // Install our source last so none of the upstream anchors can match inside the guard.
        let checkEntry = product ? "if (command.action !== 'discard') nearpaneCheck(false);" :
            "if (!['observe','discard'].includes(command.action)) nearpaneCheck(false);"
        try replace(entry, gate + "\n" + checkEntry + "\n" + entry)
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
