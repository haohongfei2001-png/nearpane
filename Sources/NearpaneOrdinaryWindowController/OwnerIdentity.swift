import AppKit
import Darwin
import Security

protocol OrdinaryApplicationReference: AnyObject {
    var processIdentifier: pid_t { get }
    var executableURL: URL? { get }
    var bundleIdentifier: String? { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isTerminated: Bool { get }
}
extension NSRunningApplication: OrdinaryApplicationReference {}

/// A PID can be recycled and a running process can exec another binary. Each sample
/// brackets the live AppKit and signing checks with independent kernel reads.
struct OrdinaryProcessImage: Equatable {
    let pid: pid_t
    let launch: UInt64
    let executable: URL
    let device: dev_t
    let inode: ino_t

    static func read(_ pid: pid_t) throws -> Self {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        try require(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, "系统未返回完整的窗口进程身份。")
        try require(info.pbi_pid == UInt32(pid) && info.pbi_uid == getuid(), "系统返回的窗口进程或用户身份不符。")
        guard let path = executablePath(pid)?.resolvingSymlinksInPath() else { throw Refusal("系统未返回窗口进程的可执行文件。") }
        var file = stat()
        try require(stat(path.path, &file) == 0 && (file.st_mode & S_IFMT) == S_IFREG, "无法核对窗口进程的可执行文件。")
        return Self(pid: pid, launch: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                    executable: path, device: file.st_dev, inode: file.st_ino)
    }

    static func signingDigest(_ pid: pid_t) throws -> Data {
        var guest: SecCode?, code: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String:pid] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, .init(rawValue:kSecCSSigningInformation), &info) == errSecSuccess,
              let digest = (info as? [String:Any])?[kSecCodeInfoUnique as String] as? Data, !digest.isEmpty
        else { throw Refusal("无法确认所选进程当前的代码签名。") }
        return digest
    }
}

/// One worker handles one explicitly selected process. Reuse the live AppKit object
/// between requests. Its mutable policy and termination state are still checked every time.
final class OrdinaryOwnerIdentity {
    private var bound: (app: any OrdinaryApplicationReference, image: OrdinaryProcessImage, digest: Data, bundle: String)?

    func verify(_ pid: pid_t, launch: UInt64, bundle: String,
                kernel: (pid_t) throws -> OrdinaryProcessImage = OrdinaryProcessImage.read,
                signing: (pid_t) throws -> Data = OrdinaryProcessImage.signingDigest,
                find: (pid_t) -> (any OrdinaryApplicationReference)? = { NSRunningApplication(processIdentifier: $0) }) throws {
        let before = try kernel(pid)
        try require(before.pid == pid && before.launch == launch, "窗口进程的启动代际不符。")
        let app: any OrdinaryApplicationReference
        if let bound {
            try require(bound.image == before && bound.bundle == bundle, "进程身份或可执行文件已变化，原窗口授权失效。")
            app = bound.app
        } else {
            guard let found = find(pid) else { throw Refusal("系统无法确认所选应用仍在运行。") }
            app = found
        }
        try require(app.processIdentifier == pid && app.bundleIdentifier == bundle, "当前应用的 PID 或 Bundle ID 与授权时不符。")
        try require(app.executableURL?.resolvingSymlinksInPath() == before.executable, "系统与应用的可执行文件位置不一致。")
        try require(!app.isTerminated, "所选应用进程已结束。")
        try require(app.activationPolicy == .regular, "系统未将所选进程确认为普通应用。")
        let digest = try signing(pid)
        if let bound { try require(bound.digest == digest, "进程当前代码签名与授权时不符。") }
        let after = try kernel(pid)
        try require(before == after, "核对途中进程身份或可执行文件已变化。")
        bound = (app, before, digest, bundle)
    }
}
