#if NEARPANE_P0_DIAGNOSTIC
import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

/// Compiled only into the short-lived acceptance candidate. Its sealed public key authorizes one
/// particular pair of real documents; a normal capability probe never consults this file.
package struct P0DiagnosticGrant: Codable, Equatable {
    package struct Space: Codable, Equatable { package let id: UInt64, type: Int, uuid: UUID }
    package struct Topology: Codable, Equatable { package let display: UUID, records: [Space], current: UInt64 }
    package struct Window: Codable, Equatable {
        package let pid: Int32, birth: UInt64, number: UInt32, executable: String, identifier: String, hash: String
        package var identity: NativeSpaceWindow { .init(pid: pid, birth: birth, number: number) }
    }
    package let operation, generation, observerSession: UUID
    package let revision: String, home: String, hostPID: Int32, hostBirth: UInt64, hostHash: String
    package let issued: Double, expires: Double, observerPID: Int32, observerBirth: UInt64, observerExecutable: String, observerHash: String
    package let topology: Topology, sourceWindow, targetWindow: Window, target: UInt64
    package let hid, additionalHID: [UInt32]
    package var sourceSpace: Space? { topology.records.first { $0.id == topology.current } }
    package var targetSpace: Space? { topology.records.first { $0.id == target } }

    package func valid(at now: Double) -> Bool {
        let rows = topology.records
        guard (0...8).contains(expires-issued), issued <= now, now <= expires,
              hostPID > 1, hostBirth > 0, hostHash.count == 40, revision.count == 40, observerPID > 1, observerBirth > 0,
              observerHash.count == 40, observerExecutable.hasPrefix("/private/tmp/nearpane-p0-drift."),
              observerExecutable.hasSuffix("/p0-drift-reader"), URL(fileURLWithPath:observerExecutable).pathComponents.count == 5,
              hid.count == 8, additionalHID.count == 8, rows.count <= 256,
              Set(rows.map(\.id)).count == rows.count, Set(rows.map(\.uuid)).count == rows.count,
              rows.allSatisfy({ $0.id > 0 }), let a = rows.firstIndex(where: { $0.id == topology.current && $0.type == 0 }),
              let b = rows.firstIndex(where: { $0.id == target && $0.type == 0 }), abs(b-a) == 1,
              Set([sourceWindow.identifier,targetWindow.identifier]) == ["net.example.spaces-document","net.example.spaces-route-witness"],
              sourceWindow.pid != targetWindow.pid, sourceWindow.number != targetWindow.number else { return false }
        let endpoints = [sourceWindow,targetWindow]
        let kits = endpoints.compactMap { window -> String? in
            let name = window.identifier == "net.example.spaces-document" ? "Field Notes" : "Route Notes"
            let suffix = "/"+name+".app/Contents/MacOS/FieldNotes"
            guard window.pid > 1, window.birth > 0, window.number > 0, window.hash.count == 40,
                  window.executable.hasSuffix(suffix) else { return nil }
            let kit = String(window.executable.dropLast(suffix.count))
            guard kit.hasPrefix("/private/tmp/nearpane-d01."), !kit.dropFirst("/private/tmp/".count).contains("/") else { return nil }
            return kit
        }
        return kits.count == 2 && kits[0] == kits[1]
    }

    package func matches(_ command: NativeSpaceCommand) -> Bool {
        command.action == .select && command.id == operation && UUID(uuidString:command.display) == topology.display &&
        command.source == String(topology.current) && command.target == String(target) &&
        command.sourceUUID == sourceSpace?.uuid && command.targetUUID == targetSpace?.uuid &&
        command.sourceKind == .ordinary && command.targetKind == .ordinary &&
        command.window == targetWindow.identity && command.originalWindow != nil
    }
}

package struct P0DiagnosticLease {
    package static let bundlePath = "/Applications/Nearpane.app"
    package static let hostExecutable = bundlePath + "/Contents/MacOS/NearpaneHost"
    package struct Envelope: Codable { package let payload, signature: Data }
    package let home, caches: URL
    package let key: Curve25519.Signing.PublicKey
    package let revision: String
    package var fingerprint: String { SHA256.hash(data:key.rawRepresentation).map { String(format:"%02x",$0) }.joined() }

    package static func privateDirectory(_ path: String) -> Bool {
        var s = stat()
        return lstat(path,&s) == 0 && s.st_mode & S_IFMT == S_IFDIR && s.st_uid == getuid() && s.st_mode & 0o077 == 0
    }

    package static func installed() -> Self? {
        guard let raw = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], let pw = getpwuid(getuid()) else { return nil }
        let home = URL(fileURLWithPath:raw), parent = home.deletingLastPathComponent()
        let caches = URL(fileURLWithPath:String(cString:pw.pointee.pw_dir)).appendingPathComponent("Library/Caches")
        guard home.path == home.resolvingSymlinksInPath().path, parent.deletingLastPathComponent().path == caches.path,
              parent.lastPathComponent.hasPrefix("nearpane-native-acceptance."), privateDirectory(parent.path), privateDirectory(home.path),
              let app = Bundle(path:bundlePath), let value = app.object(forInfoDictionaryKey:"NearpaneP0DiagnosticPublicKey") as? String,
              let data = Data(base64Encoded:value), let key = try? Curve25519.Signing.PublicKey(rawRepresentation:data),
              let revision = app.object(forInfoDictionaryKey:"NearpaneSourceRevision") as? String,
              app.bundleIdentifier == "com.holdsnow.nearpane.alpha", app.object(forInfoDictionaryKey:"CFBundleVersion") as? String == "90",
              app.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String == "5.22",
              systemBuild() == "26A428" else { return nil }
        return Self(home:home,caches:caches,key:key,revision:revision)
    }

    private static func systemBuild() -> String? {
        var bytes = [CChar](repeating:0,count:128), size = bytes.count
        guard sysctlbyname("kern.osversion",&bytes,&size,nil,0) == 0 else { return nil }
        return String(cString:bytes)
    }

    package static func decoded(_ bytes: Data, key: Curve25519.Signing.PublicKey, now: Double) throws -> P0DiagnosticGrant {
        let envelope = try JSONDecoder().decode(Envelope.self,from:bytes)
        guard key.isValidSignature(envelope.signature,for:envelope.payload) else { throw WindowIdentityFailure("diagnosticLeaseSignature") }
        let grant = try JSONDecoder().decode(P0DiagnosticGrant.self,from:envelope.payload)
        guard grant.valid(at:now) else { throw WindowIdentityFailure("diagnosticLeaseBoundsOrExpiration") }
        return grant
    }

    package var file: URL { home.appendingPathComponent("p0-host-one-shot.json") }
    private func readFile(_ url: URL) throws -> Data {
        let fd = open(url.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw WindowIdentityFailure("diagnosticLeaseUnavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, (1...32768).contains(info.st_size) else { throw WindowIdentityFailure("diagnosticLeaseFile") }
        let bytes = try FileHandle(fileDescriptor:fd,closeOnDealloc:false).readToEnd() ?? Data()
        guard bytes.count == info.st_size else { throw WindowIdentityFailure("diagnosticLeaseChanged") }
        return bytes
    }

    package func read(host pid: pid_t) throws -> P0DiagnosticGrant {
        let grant = try Self.decoded(readFile(file),key:key,now:ProcessInfo.processInfo.systemUptime)
        let root = home.appendingPathComponent("Library/Application Support/Nearpane Alpha Profiles")
        struct Index: Decodable { let format: Int, active: UUID }
        let index = try JSONDecoder().decode(Index.self,from:Data(contentsOf:root.appendingPathComponent("profile-index.json")))
        guard grant.home == home.path, grant.revision == revision, index.format == 1, index.active == grant.generation,
              pid == grant.hostPID, Self.productSignature(pid), try Self.verify(pid,grant.hostBirth,Self.hostExecutable,grant.hostHash),
              try Self.verify(grant.sourceWindow), try Self.verify(grant.targetWindow),
              Self.privateDirectory(URL(fileURLWithPath:grant.observerExecutable).deletingLastPathComponent().path),
              try Self.verify(grant.observerPID,grant.observerBirth,grant.observerExecutable,grant.observerHash),
              Self.hid() == grant.hid, Self.hid(extra:true) == grant.additionalHID else {
            throw WindowIdentityFailure("diagnosticProcessProfileObserverOrInputChanged")
        }
        return grant
    }

    private static func productSignature(_ pid: pid_t) -> Bool {
        var code: SecCode?, requirement: SecRequirement?
        let clause = #"identifier "com.holdsnow.nearpane.alpha" and anchor apple generic and certificate leaf[subject.OU] = "ZB9D4T66QB""#
        guard SecRequirementCreateWithString(clause as CFString,[],&requirement) == errSecSuccess, let requirement,
              SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code) == errSecSuccess, let code
        else { return false }
        return SecCodeCheckValidity(code,[],requirement) == errSecSuccess
    }

    private static func verify(_ pid: pid_t, _ birth: UInt64, _ path: String, _ hash: String) throws -> Bool {
        let image = try OrdinaryProcessImage.read(pid)
        let digest = try OrdinaryProcessImage.signingDigest(pid).map { String(format:"%02x",$0) }.joined()
        let canonical = URL(fileURLWithPath:path).resolvingSymlinksInPath().path
        return image.launch == birth && image.executable.path == canonical && digest == hash && (try? OrdinaryProcessImage.read(pid)) == image
    }

    private static func verify(_ window: P0DiagnosticGrant.Window) throws -> Bool {
        let kit = URL(fileURLWithPath:window.executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard privateDirectory(kit.path) else { return false }
        return try verify(window.pid,window.birth,window.executable,window.hash)
    }

    private struct Enrollment: Decodable {
        struct Endpoint: Decodable { let window: P0DiagnosticGrant.Window, display: UUID, space: UInt64, spaceUUID: UUID }
        let intent: String, revision: String, home: String, generation: UUID, hostPID: pid_t, hostBirth: UInt64, hostHash: String
        let issued: Double, expires: Double, endpoints: [Endpoint]
    }

    /// Read-only, signed enrollment while each real document is on screen. No command can
    /// decode this schema. This path cannot turn on the global background-window inventory.
    package func observationTargets(host pid: pid_t) -> Set<NativeSidebarWindowLocation>? {
        let url = home.appendingPathComponent("p0-host-observe.json")
        guard let data = try? readFile(url), let signed = try? JSONDecoder().decode(Envelope.self,from:data),
              key.isValidSignature(signed.signature,for:signed.payload),
              let roster = try? JSONDecoder().decode(Enrollment.self,from:signed.payload),
              roster.intent == "retain-fixture-originals", roster.revision == revision, roster.home == home.path,
              roster.hostPID == pid, Self.productSignature(pid), (try? Self.verify(pid,roster.hostBirth,Self.hostExecutable,roster.hostHash)) == true,
              (1...2).contains(roster.endpoints.count), (0...300).contains(roster.expires-roster.issued),
              (roster.issued...roster.expires).contains(ProcessInfo.processInfo.systemUptime),
              let index = try? Data(contentsOf:home.appendingPathComponent("Library/Application Support/Nearpane Alpha Profiles/profile-index.json")),
              let info = try? JSONSerialization.jsonObject(with:index) as? [String:Any],
              let active = info["active"] as? String, UUID(uuidString:active) == roster.generation else { return nil }
        var result = Set<NativeSidebarWindowLocation>()
        for endpoint in roster.endpoints {
            let w = endpoint.window
            guard let name = ["net.example.spaces-document":"Field Notes","net.example.spaces-route-witness":"Route Notes"][w.identifier],
                  w.executable.hasSuffix("/"+name+".app/Contents/MacOS/FieldNotes"),
                  w.executable.hasPrefix("/private/tmp/nearpane-d01."), URL(fileURLWithPath:w.executable).pathComponents.count == 8,
                  w.number > 0, endpoint.space > 0, (try? Self.verify(w)) == true else { return nil }
            result.insert(.init(window:w.identity,display:endpoint.display,space:String(endpoint.space),spaceUUID:endpoint.spaceUUID))
        }
        return result.count == roster.endpoints.count ? result : nil
    }

    package static func hid(extra: Bool = false) -> [UInt32] {
        let kinds: [CGEventType] = extra ? [.mouseMoved,.keyUp,.flagsChanged,.leftMouseUp,.rightMouseUp,.otherMouseUp,.tabletPointer,.tabletProximity] :
            [.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged]
        return kinds.map { CGEventSource.counterForEventType(.hidSystemState,eventType:$0) }
    }

    /// O_EXCL persists across profile deletion, relaunch and a new lease for the same sealed key.
    /// An ambiguous outcome leaves the slot spent. Only the action worker claims this immediately before dispatch.
    package static func spend(in directory: URL, campaign: String, operation: UUID) throws {
        guard campaign.count == 64, campaign.allSatisfy(\.isHexDigit),
              mkdir(directory.path,0o700) == 0 || errno == EEXIST, privateDirectory(directory.path) else {
            throw WindowIdentityFailure("diagnosticSpendDirectory")
        }
        let dir = open(directory.path,O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard dir >= 0 else { throw WindowIdentityFailure("diagnosticSpendDirectory") }
        defer { close(dir) }
        let fd = openat(dir,campaign,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw WindowIdentityFailure("diagnosticCandidateAlreadySpent") }
        defer { close(fd) }
        let record = Data(operation.uuidString.utf8)
        try FileHandle(fileDescriptor:fd,closeOnDealloc:false).write(contentsOf:record)
        guard fsync(fd) == 0, fsync(dir) == 0 else { throw WindowIdentityFailure("diagnosticSpendNotDurable") }
    }

    package func spend(_ grant: P0DiagnosticGrant) throws {
        try Self.spend(in:caches.appendingPathComponent("nearpane-p0-diagnostic-spent"),campaign:fingerprint,operation:grant.operation)
    }
}
#endif
