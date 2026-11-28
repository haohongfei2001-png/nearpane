import CryptoKit
import Darwin
import Foundation
import NearpaneCore
import Security

@MainActor enum AppleStageProductAdmission {
    // The signed product pins an independent QA key and receipt ID. A detached
    // receipt can bind the final CDHash without embedding that hash in its own image.
    enum Route: String { case focus = "apple.native-focus", merge = "apple.native-strip-merge" }
    private static let admitted: [Route: StageWindowEngineAttestation.Pin] = [:]
    private struct Qualification: Decodable {
        let version: Int, route, build, source, hostCDHash: String, evidence: UUID
        let exactReceiver, unrelatedStagesPreserved: Bool
        let physicalNativeMerge, releasedInput, physicalNativeFocus, completeWorksetCycle: Bool?
        func confirms(_ route: Route) -> Bool {
            guard exactReceiver && unrelatedStagesPreserved else { return false }
            switch route {
            case .focus: return physicalNativeFocus == true && completeWorksetCycle == true
            case .merge: return physicalNativeMerge == true && releasedInput == true
            }
        }
    }
    static func permits(_ route: Route) -> Bool {
        guard let pin = admitted[route],
              let revision = Bundle.main.object(forInfoDictionaryKey: "NearpaneSourceRevision") as? String,
              Bundle.main.bundleIdentifier == "com.holdsnow.nearpane.alpha",
              Bundle.main.bundleURL.resolvingSymlinksInPath().path == "/Applications/Nearpane.app",
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let hash = try? OrdinaryProcessImage.signingDigest(getpid()) else { return false }
        let url = support.appendingPathComponent("Nearpane/StageEngineEvidence")
            .appendingPathComponent(pin.evidence.uuidString + ".json")
        guard (try? ProfileLease.checkPath(url)) != nil else { return false }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0, fileInfo.st_mode & S_IFMT == S_IFREG, (1...98_304).contains(fileInfo.st_size),
              let data = try? file.read(upToCount: 98_305), data.count == fileInfo.st_size,
              let envelope = try? JSONDecoder().decode(StageWindowEngineAttestation.Envelope.self, from: data),
              envelope.version == 1, envelope.payload.count <= 65_536,
              let key = try? P256.Signing.PublicKey(derRepresentation: pin.publicKeyDER),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: envelope.signature),
              key.isValidSignature(signature, for: envelope.payload),
              let receipt = try? JSONDecoder().decode(Qualification.self, from: envelope.payload),
              receipt.version == 1, receipt.route == route.rawValue, receipt.evidence == pin.evidence,
              receipt.confirms(route),
              receipt.source == revision, receipt.hostCDHash == hash.map({ String(format: "%02x", $0) }).joined(),
              let requirement = teamRequirement else { return false }
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, (2...128).contains(size) else { return false }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0,
              receipt.build == String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        else { return false }
        var running: SecCode?
        return SecCodeCopySelf([], &running) == errSecSuccess &&
            running.map { SecCodeCheckValidity($0, [], requirement) } == errSecSuccess
    }
    private static let teamRequirement: SecRequirement? = {
        var r: SecRequirement?
        let requirement = "anchor apple generic and identifier \"com.holdsnow.nearpane.alpha\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
        return SecRequirementCreateWithString(requirement as CFString, [], &r) == errSecSuccess ? r : nil
    }()
}
