import AppKit
import NearpaneCore

/// An active stream may independently re-prove a missing owner read. A positive denial never takes this path.
final class DesktopPreviewOwner {
    enum Gap {
        case kernel, application, bundle

        func evidence(recovered: Bool) -> PreviewPipelineAudit.Reason {
            switch self {
            case .kernel: return recovered ? .kernelReadRecovered : .kernelReadMissing
            case .application: return recovered ? .applicationLookupRecovered : .applicationLookupMissing
            case .bundle: return recovered ? .bundleReadRecovered : .bundleReadMissing
            }
        }
    }

    enum Read<App> {
        case found(App, bundle: String), missing(Gap), denied
    }

    private let identity = OrdinaryOwnerIdentity()
    private let key: DesktopWindowKey, bundle: String

    init?(key: DesktopWindowKey, app: any OrdinaryApplicationReference,
          kernel: (pid_t) throws -> OrdinaryProcessImage = OrdinaryProcessImage.read,
          signing: (pid_t) throws -> Data = OrdinaryProcessImage.signingDigest) {
        guard let bundle = app.bundleIdentifier, Self.permitted(bundle) else { return nil }
        self.key = key; self.bundle = bundle
        do {
            try identity.verify(key.pid, launch: key.birth, bundle: bundle, kernel: kernel, signing: signing, find: { _ in app })
        } catch { return nil }
    }

    private static func permitted(_ bundle: String) -> Bool {
        !bundle.isEmpty && !bundle.hasPrefix("com.holdsnow.nearpane") && !bundle.hasPrefix("org.nearpane.")
    }

    func stillSigned(as candidate: DesktopWindowKey,
                     kernel: (pid_t) throws -> OrdinaryProcessImage = OrdinaryProcessImage.read,
                     signing: (pid_t) throws -> Data = OrdinaryProcessImage.signingDigest) -> Bool {
        guard key == candidate else { return false }
        do { try identity.verify(key.pid, launch: key.birth, bundle: bundle, kernel:kernel, signing:signing); return true }
        catch { return false }
    }

    static func generationMatches(_ key: DesktopWindowKey) -> Bool? {
        guard key.pid > 1, key.birth > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(key.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_pid == UInt32(key.pid) && info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec == key.birth
    }

    static func read<App: OrdinaryApplicationReference>(_ key: DesktopWindowKey,
            generation: (DesktopWindowKey) -> Bool? = generationMatches, find: (pid_t) -> App?) -> Read<App> {
        guard let matches = generation(key) else { return .missing(.kernel) }
        guard matches else { return .denied }
        guard let app = find(key.pid) else { return .missing(.application) }
        guard app.processIdentifier == key.pid, !app.isTerminated, app.activationPolicy == .regular else { return .denied }
        guard let bundle = app.bundleIdentifier, !bundle.isEmpty else { return .missing(.bundle) }
        return permitted(bundle) ? .found(app, bundle: bundle) : .denied
    }

    static func resolve<App: OrdinaryApplicationReference>(_ read: Read<App>, key: DesktopWindowKey, bound: DesktopPreviewOwner?,
            kernel: (pid_t) throws -> OrdinaryProcessImage = OrdinaryProcessImage.read,
            signing: (pid_t) throws -> Data = OrdinaryProcessImage.signingDigest) -> (allowed: Bool, evidence: PreviewPipelineAudit.Reason) {
        switch read {
        case .found(_, let bundle):
            let allowed = bound.map { $0.key == key && $0.bundle == bundle } ?? true
            return (allowed, allowed ? .allowed : .ownerChanged)
        case .denied:
            return (false, .ownerChanged)
        case .missing(let gap):
            guard let bound, bound.key == key else { return (false, gap.evidence(recovered: false)) }
            do {
                // The retained NSRunningApplication must still be live and regular. Verify the
                // kernel process image twice, its current code signature, executable and bundle.
                try bound.identity.verify(key.pid, launch: key.birth, bundle: bound.bundle, kernel: kernel,
                                          signing: signing, find: { _ in nil })
                return (true, gap.evidence(recovered: true))
            } catch { return (false, gap.evidence(recovered: false)) }
        }
    }
}
