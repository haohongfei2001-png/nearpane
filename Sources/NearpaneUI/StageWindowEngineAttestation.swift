import AppKit
import CryptoKit
import Darwin
import Foundation
import NearpaneCore

/// The shipped code can pin a physical receipt ID and independent signing key before the final Host is
/// signed. The detached physical result can then refer to its actual runtime cdhash without self-reference.
enum StageWindowEngineAttestation {
    struct Pin { let evidence: UUID, publicKeyDER: Data }
    struct Envelope: Codable { let version: Int, payload, signature: Data }
    static func verify(_ data: Data, pin: Pin) -> StageEngineQualification? {
        guard data.count <= 98_304, let envelope = try? JSONDecoder().decode(Envelope.self,from:data),
              envelope.version == 1, envelope.payload.count <= 65_536,
              let key = try? P256.Signing.PublicKey(derRepresentation:pin.publicKeyDER),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation:envelope.signature),
              key.isValidSignature(signature,for:envelope.payload),
              let receipt = try? JSONDecoder().decode(StageEngineQualification.self,from:envelope.payload),
              receipt.evidence == pin.evidence else { return nil }
        return receipt
    }
    static func read(_ pin: Pin, profile: URL) -> StageEngineQualification? {
        let url = profile.appendingPathComponent("StageEngineEvidence").appendingPathComponent(pin.evidence.uuidString + ".json")
        guard (try? ProfileLease.checkPath(url)) != nil else { return nil }
        let fd = open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        var info = stat()
        guard fstat(fd,&info) == 0, (info.st_mode & S_IFMT) == S_IFREG, (1...98_304).contains(info.st_size),
              let data = try? file.read(upToCount:Int(info.st_size)+1), data.count == info.st_size else { return nil }
        return verify(data,pin:pin)
    }

    private static func systemString(_ key: String) -> String? {
        var count = 0
        guard sysctlbyname(key,nil,&count,nil,0) == 0, (2...512).contains(count) else { return nil }
        var storage = [CChar](repeating:0,count:count)
        guard sysctlbyname(key,&storage,&count,nil,0) == 0 else { return nil }
        return String(decoding:storage.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),as:UTF8.self)
    }

    static func currentPermissions() -> Set<StageVisibilityPermission> {
        var permissions = Set<StageVisibilityPermission>()
        if AXIsProcessTrusted() { permissions.insert(.accessibility) }
        if CGPreflightListenEventAccess() { permissions.insert(.listenEvent) }
        if CGPreflightPostEventAccess() { permissions.insert(.postEvent) }
        if CGPreflightScreenCaptureAccess() { permissions.insert(.screenCapture) }
        return permissions
    }

    @MainActor static func installedEnvironment(_ snapshot: DesktopSnapshot) -> StageEngineEnvironment? {
        guard (Bundle.main.bundleURL.resolvingSymlinksInPath().path == "/Applications/Nearpane.app" || IndependentStagePolicy.candidateRequested),
              let revision = Bundle.main.object(forInfoDictionaryKey:"NearpaneSourceRevision") as? String,
              let build = systemString("kern.osversion"), let hardware = systemString("hw.model"),
              let image = try? OrdinaryProcessImage.signingDigest(getpid()), let process = dlopen(nil,RTLD_LAZY) else { return nil }
        defer { dlclose(process) }
        guard let fn = dlsym(process,"csr_get_active_config") else { return nil }
        let sip = unsafeBitCast(fn,to:(@convention(c)(UnsafeMutablePointer<UInt32>)->Int32).self)
        var posture: UInt32 = .max
        guard sip(&posture) == 0, posture == 0 || IndependentStagePolicy.candidateRequested else { return nil }
        var parts = [String]()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let mode = CGDisplayCopyDisplayMode(number.uint32Value), CGDisplayIsInMirrorSet(number.uint32Value) == 0,
                  screen.maximumFramesPerSecond > 0 else { return nil }
            let name = CFUUIDCreateString(nil,uuid) as String
            guard let d = snapshot.displays.first(where:{ $0.id.caseInsensitiveCompare(name) == .orderedSame }),
                  d.backingScale == screen.backingScaleFactor,
                  CGRect(x:d.frame.x,y:d.frame.y,width:d.frame.width,height:d.frame.height) == CGDisplayBounds(number.uint32Value)
            else { return nil }
            parts.append([d.id.lowercased(),String(mode.pixelWidth),String(mode.pixelHeight),String(mode.refreshRate),
                          String(screen.maximumFramesPerSecond),String(d.backingScale),String(d.rotationDegrees),
                          String(d.frame.x),String(d.frame.y)].joined(separator:"/"))
        }
        guard parts.count == snapshot.displays.count, Set(parts).count == parts.count, !parts.isEmpty else { return nil }
        let topology = SHA256.hash(data:Data(parts.sorted().joined(separator:"|").utf8)).map { String(format:"%02x",$0) }.joined()
        return .init(osBuild:build,engineRevision:revision,hostCDHash:image.map { String(format:"%02x",$0) }.joined(),
                     hardware:hardware,topology:topology,windowClass:"ordinary-standard",sipEnabled:posture == 0,permissions:currentPermissions())
    }
}
