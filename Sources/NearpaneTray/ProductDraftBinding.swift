import AppKit
import Carbon
import Darwin
import RiftletAdapters
import RiftletCore
import Security

struct DraftAutomationUnavailable: Error {
    let state: AutomationPermissionState
}

extension AutomationPermissionState {
    var attachmentNotice: String? {
        switch self {
        case .granted: nil
        case .browserNotRunning: "请打开 Chrome，再重新检查草稿附加权限。"
        case .browserNotInstalled: "此 Mac 未找到 Chrome，截图可继续留在托盘。"
        case .denied: "请在系统设置的「隐私与安全性 → 自动化」中允许 Nearpane 控制 Chrome，再重新检查。"
        case .notRequested: "尚未授予 Nearpane 控制 Chrome 的权限。"
        case .unavailable, .notNeeded: "无法核实当前 Chrome 或附件守卫，请确认目标浏览器后重新检查。"
        }
    }
}

/// The page owns the document/editor references. Only this short-lived witness, never draft text or its URL,
/// is stored with the input claim so read-only reconciliation can address the original invocation.
struct ProductDraftBinding: Codable, Equatable, Sendable {
    let nonce, process, window, tab, assetID, sha256: String
    let boundAt, expiresAt: Double
    var timeOrigin: Double

    func accepts(_ target: TargetLease) -> Bool {
        target.adapterID == "chatgpt-web" && target.applicationID == "com.google.Chrome" &&
        target.surface == .webChat && target.sessionID == process && target.windowID == window && target.tabID == tab &&
        !target.documentID.isEmpty && !target.composerID.isEmpty && !target.draftGeneration.isEmpty &&
        target.clickBindingID?.uuidString.lowercased() == nonce
    }

    private static func signedChrome(pid: pid_t) -> Bool {
        let rule = #"anchor apple generic and identifier "com.google.Chrome" and certificate leaf[subject.OU] = "EQHXZ8M8AV""#
        var requirement: SecRequirement?
        var process: SecCode?
        let query = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        return SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess &&
            SecCodeCopyGuestWithAttributes(nil, query, [], &process) == errSecSuccess &&
            process.map { SecCodeCheckValidity($0, [], requirement) == errSecSuccess } == true
    }

    static func armScript(draft: Self, guardSource: String) throws -> String {
        let spec = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        return "(" + guardSource + ")({...(" + spec + "),mode:'product'},{action:'armProductDraft'})"
    }

    @MainActor static func arm(_ asset: ImportedAsset, guardSource: String) throws -> Self {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.google.Chrome",
              let identity = ChromeProcessIdentity.read(pid: app.processIdentifier), signedChrome(pid: identity.pid)
        else { throw WebAdapterError.browserNotFrontmost }
        // The persisted checkbox is user intent. Check the authority of this exact
        // running process before the first browser event, without requesting consent.
        let address = NSAppleEventDescriptor(processIdentifier: identity.pid)
        let status = AEDeterminePermissionToAutomateTarget(address.aeDesc, typeWildCard, typeWildCard, false)
        let access = NativeAutomationPermissionChecker.classify(status)
        guard access == .granted else { throw DraftAutomationUnavailable(state: access) }
        guard identity.isCurrent(), NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.pid
        else { throw WebAdapterError.browserNotFrontmost }
        let route = try AcceptanceBrowserRoute.front(pid: identity.pid)
        let url = try route.selectedURL()
        guard url.scheme == "https", url.host == "chatgpt.com", url.port == nil, url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/" || url.path.range(of: #"^/c/[A-Za-z0-9-]+/?$"#, options: .regularExpression) != nil,
              identity.isCurrent() else { throw WebAdapterError.invalidTarget }
        let now = Date().timeIntervalSince1970
        var b = Self(nonce: UUID().uuidString.lowercased(), process: identity.session, window: route.windowID, tab: route.tabID,
                     assetID: asset.id.uuidString.lowercased(), sha256: asset.sha256, boundAt: now, expiresAt: now + 120, timeOrigin: 0)
        struct Reply: Decodable { let timeOrigin: Double }
        // Run at mouse-down, before any asynchronous resolution can bind a new document or editor.
        let result = try route.observe(armScript(draft: b, guardSource: guardSource))
        b.timeOrigin = try JSONDecoder().decode(Reply.self, from: Data(result.utf8)).timeOrigin
        guard b.timeOrigin.isFinite, b.timeOrigin > 0, identity.isCurrent(), try route.selectedURL() == url
        else { throw WebAdapterError.invalidTarget }
        return b
    }

    @MainActor func requireSelected() throws {
        let segments = process.split(separator: ":")
        guard segments.count == 4, let pid = Int32(segments[1]),
              ChromeProcessIdentity.read(pid: pid)?.session == process, Self.signedChrome(pid: pid),
              try AcceptanceBrowserRoute(pid: pid, window: window, tab: tab).selected() else {
            throw WebAdapterError.invalidTarget
        }
    }

    static func composed(_ original: WebPageProgram, guardSource: String) throws -> WebPageProgram {
        // A stable function permits reusing the original Riftlet relay, including observe-only
        // recovery. Each click and every command after capture must still match its own page witness.
        let read = """
        (() => {
          const root = document.documentElement;
          const id = command.action === 'captureTarget' ? root.getAttribute('data-nearpane-selected-image-v1')
            : command.target?.clickBindingID?.toLowerCase();
          if (!id || !/^[0-9a-f-]{36}$/.test(id)) throw Error('TARGET_INVALID');
          const b = JSON.parse(root.getAttribute('data-nearpane-image-' + id));
          if (!b || b.mode !== 'product' || b.nonce !== id) throw Error('TARGET_INVALID');
          return b;
        })()
        """
        return try GuardedDraftProgram.compose(original, guardSource: guardSource, binding: read, product: true)
    }

    func program(_ original: WebPageProgram, guardSource: String) throws -> WebPageProgram {
        try Self.composed(original, guardSource: guardSource)
    }
}

enum ImportedAttachmentError: Error { case previousAttempt }

@MainActor final class ProductDraftExecutor: WebClickTargetPinning {
    typealias Arm = @MainActor (ImportedAsset) throws -> ProductDraftBinding
    typealias Selected = @MainActor (ProductDraftBinding) throws -> Void

    private struct Click {
        let binding: ProductDraftBinding, target: TargetLease
        var identity: ObservationIdentity?
        var invocation: UUID?
    }
    private struct Claim: Codable {
        let binding: ProductDraftBinding, identity: ObservationIdentity, invocation: UUID
    }
    private let claims: URL
    private let base: any WebClickTargetPinning
    private let guardSource: String
    private let arm: Arm, selected: Selected
    private var pendingAsset: ImportedAsset?
    private var clicks = [UUID: Click]()
    private var generation = UUID()
    private var cached: (original: String, program: WebPageProgram)?

    init(root: URL, base: any WebClickTargetPinning, guardSource: String,
         arm: Arm? = nil, selected: Selected? = nil) {
        claims = root.appendingPathComponent("draft-input-claims", isDirectory: true)
        self.base = base
        self.guardSource = guardSource
        self.arm = arm ?? { try ProductDraftBinding.arm($0, guardSource: guardSource) }
        self.selected = selected ?? { try $0.requireSelected() }
    }

    func cancelSelections() {
        generation = UUID()
        pendingAsset = nil
        clicks.removeAll()
    }

    func checkAsset(_ asset: ImportedAsset) throws {
        pendingAsset = nil
        guard asset.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              asset.byteCount > 0 else { throw WebAdapterError.invalidRequest }
        try checkImportedHistory(asset.id)
        pendingAsset = asset
    }

    /// Migration retains spent asset identities without granting a new browser capability.
    private func checkImportedHistory(_ id: UUID) throws {
        let root = open(claims.deletingLastPathComponent().path, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw WebAdapterError.invalidPrivateFile }
        defer { close(root) }
        let directory = openat(root, "imported-attachment-holds", O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if directory == -1 && errno == ENOENT { return }
        guard directory >= 0 else { throw WebAdapterError.invalidPrivateFile }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw WebAdapterError.invalidPrivateFile
        }
        if fstatat(directory, id.uuidString.lowercased(), &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw ImportedAttachmentError.previousAttempt
        }
        guard errno == ENOENT else { throw WebAdapterError.invalidPrivateFile }
    }

    private func guarded(_ original: WebPageProgram) throws -> WebPageProgram {
        if let cached, cached.original == original.functionSource { return cached.program }
        let result = try ProductDraftBinding.composed(original, guardSource: guardSource)
        cached = (original.functionSource, result)
        return result
    }

    func targetForClick(program: WebPageProgram) throws -> Task<TargetLease, Error> {
        guard let asset = pendingAsset else { throw WebAdapterError.invalidRequest }
        pendingAsset = nil
        let program = try guarded(program)
        if let claim = try readClaim(asset.id) {
            guard claim.identity.assetSHA256 == asset.sha256, claim.binding.accepts(claim.identity.target) else {
                throw WebAdapterError.invalidRequest
            }
            try selected(claim.binding)
            // Only observe can use this previously spent lease.
            return Task { claim.identity.target }
        }
        let b = try arm(asset)
        guard b.assetID == asset.id.uuidString.lowercased(), b.sha256 == asset.sha256 else { throw WebAdapterError.invalidRequest }
        try selected(b)
        let current = generation
        let capture = try base.targetForClick(program: program)
        return Task {
            let target = try await withTaskCancellationHandler { try await capture.value } onCancel: { capture.cancel() }
            try Task.checkCancellation()
            try selected(b)
            let now = Date().timeIntervalSince1970
            guard generation == current, b.boundAt <= now, now < b.expiresAt,
                  b.expiresAt - b.boundAt <= 120, b.timeOrigin > 0,
                  b.accepts(target), let key = target.clickBindingID else { throw WebAdapterError.invalidTarget }
            clicks = clicks.filter { $0.value.binding.expiresAt > now }
            clicks[key] = Click(binding: b, target: target)
            return target
        }
    }

    func execute(_ command: WebBridgeCommand, program: WebPageProgram) async throws -> Data {
        guard let target = command.target, let key = target.clickBindingID else { throw WebAdapterError.invalidTarget }
        if command.action == .observe || command.action == .commit {
            guard let id = command.identity?.assetID else { throw WebAdapterError.invalidRequest }
            try checkImportedHistory(id)
        }
        let program = try guarded(program)
        if command.action == .observe {
            guard let id = command.identity, let saved = try readClaim(id.assetID), saved.identity == id,
                  saved.identity.target == target, saved.binding.accepts(target) else { throw WebAdapterError.invalidRequest }
            try selected(saved.binding)
            return try await base.execute(command, program: program)
        }
        guard var click = clicks[key], click.target == target,
              Date().timeIntervalSince1970 <= click.binding.expiresAt else { throw WebAdapterError.invalidTarget }
        try selected(click.binding)
        if command.action == .validate { return try await base.execute(command, program: program) }
        guard let id = command.identity, let invocation = command.invocationID, id.target == target, id.attempt > 0,
              id.assetID.uuidString.lowercased() == click.binding.assetID, id.assetSHA256 == click.binding.sha256,
              try readClaim(id.assetID) == nil else { throw WebAdapterError.invalidRequest }
        if command.action == .begin {
            guard click.identity == nil else { throw WebAdapterError.invalidRequest }
            click.identity = id; click.invocation = invocation; clicks[key] = click
        } else {
            guard click.identity == id, click.invocation == invocation,
                  [.chunk,.commit,.discard].contains(command.action) else { throw WebAdapterError.invalidRequest }
        }
        if command.action == .commit {
            // A lost reply or interrupted write cannot be retried by another click or Host.
            try spend(Claim(binding:click.binding, identity:id, invocation:invocation))
            clicks[key] = nil
        } else if command.action == .discard {
            clicks[key] = nil
        }
        return try await base.execute(command, program: program)
    }

    private func claimURL(_ id: UUID) throws -> URL {
        guard claims.path == claims.resolvingSymlinksInPath().path else { throw WebAdapterError.invalidPrivateFile }
        guard mkdir(claims.path, 0o700) == 0 || errno == EEXIST else { throw WebAdapterError.invalidPrivateFile }
        var st = stat()
        guard lstat(claims.path,&st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(),
              st.st_mode & 0o077 == 0 else { throw WebAdapterError.invalidPrivateFile }
        return claims.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func readClaim(_ id: UUID) throws -> Claim? {
        let file = try claimURL(id)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw WebAdapterError.invalidPrivateFile }
        let handle = FileHandle(fileDescriptor:fd, closeOnDealloc:true)
        var st = stat()
        guard fstat(fd,&st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
              (1...16384).contains(st.st_size), let bytes = try handle.read(upToCount:Int(st.st_size)),
              bytes.count == st.st_size else { throw WebAdapterError.invalidPrivateFile }
        let claim = try JSONDecoder().decode(Claim.self, from:bytes)
        guard claim.identity.assetID == id, claim.binding.assetID == id.uuidString.lowercased(),
              claim.binding.sha256 == claim.identity.assetSHA256, claim.binding.accepts(claim.identity.target)
        else { throw WebAdapterError.invalidRequest }
        return claim
    }

    private func spend(_ claim: Claim) throws {
        let file = try claimURL(claim.identity.assetID)
        let data = try JSONEncoder().encode(claim)
        let fd = open(file.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw WebAdapterError.invalidRequest }
        let handle = FileHandle(fileDescriptor:fd, closeOnDealloc:true)
        try handle.write(contentsOf:data)
        try handle.synchronize()
        let dir = open(claims.path,O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw WebAdapterError.invalidPrivateFile }
        defer { close(dir) }
        guard fsync(dir) == 0 else { throw WebAdapterError.invalidPrivateFile }
    }
}
