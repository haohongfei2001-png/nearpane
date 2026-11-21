import AppKit
import ApplicationServices
import Darwin
import Foundation
import Security
import CNearpaneWindowEngine
import NearpaneCore
import NearpaneWindowEngine

/// Runs before profile selection. The explicit installed trial operates only on the signed, nonce-bound fixture.
enum StageEnginePackageProbe {
    /// A registration only permits reading membership of a signed fixture. The sampler rebinds the
    /// process, code image and window before and after each read. This entry never submits a write.
    static func enrolledFixture(_ channel: StageScopeReply?) throws -> StageEngineHostScope.Fixture {
        struct Registration: Decodable { let pid: Int32, birth: UInt64, window: UInt32, executable: String, cdhash: String }
        let data = try channel?.registration() ?? FileHandle.standardInput.readData(ofLength: 4097)
        guard !data.isEmpty, data.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
        let item = try JSONDecoder().decode(Registration.self, from: data)
        guard item.pid > 1, item.birth > 0, item.window > 0, item.executable.hasPrefix("/"),
              item.cdhash.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return .init(pid: item.pid, birth: item.birth, number: item.window,
                     executable: URL(fileURLWithPath: item.executable), cdhash: item.cdhash)
    }

    private static func systemEvidence() -> [String: Any] {
        var size = 0
        var build: String?
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, (2...256).contains(size) {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 {
                build = String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            }
        }
        var sip: [String: Any] = ["source": "Host/csr_get_active_config", "status": "UNKNOWN"]
        if let handle = dlopen(nil, RTLD_LAZY) {
            defer { dlclose(handle) }
            if let symbol = dlsym(handle, "csr_get_active_config") {
                let read = unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutablePointer<UInt32>) -> Int32).self)
                var bits = UInt32.max
                let result = read(&bits)
                sip["returnCode"] = result
                if result == 0 { sip["status"] = "OBSERVED"; sip["bits"] = bits; sip["enabled"] = bits == 0 }
            }
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return ["version": [v.majorVersion,v.minorVersion,v.patchVersion], "versionSource": "Host/ProcessInfo",
                "build": build as Any? ?? NSNull(), "buildSource": "Host/sysctl kern.osversion", "sip": sip]
    }

    private static func liveSigner(_ bundle: Bundle) throws -> (team: String, digest: Data) {
        var live: SecCode?, file: SecStaticCode?, information: CFDictionary?, rule: SecRequirement?
        let expected = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
        guard SecRequirementCreateWithString(expected as CFString, [], &rule) == errSecSuccess, let rule,
              SecCodeCopySelf([], &live) == errSecSuccess, let live,
              SecCodeCheckValidity(live, SecCSFlags(rawValue: kSecCSStrictValidate), rule) == errSecSuccess,
              SecCodeCopyStaticCode(live, [], &file) == errSecSuccess, let file,
              SecCodeCopySigningInformation(file, .init(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let id = info[kSecCodeInfoIdentifier as String] as? String, id == bundle.bundleIdentifier,
              ["com.holdsnow.nearpane.alpha", "com.holdsnow.nearpane.host"].contains(id),
              let digest = info[kSecCodeInfoUnique as String] as? Data, !digest.isEmpty else { throw CocoaError(.fileReadNoPermission) }
        return (team, digest)
    }

    static func admitsInstalledCycle(preflight: [String: Any]?, registered: [String: Any]) -> Bool {
        guard let scope = registered["spaceScope"] as? [String: Any], let member = scope["fixtureMembership"] as? [String: Any],
              member["status"] as? String == "PASS",
              ["spaceToWindow","windowToSpaces"].allSatisfy({ (member[$0] as? [String:Any])?["status"] as? String == "PASS" })
        else { return false }
        return admitsPhysicalScope(preflight: preflight, current: registered)
    }

    static func admitsPhysicalScope(preflight: [String: Any]?, current registered: [String: Any]) -> Bool {
        guard let preflight, let before = preflight["spaceScope"] as? [String: Any], let final = registered["spaceScope"] as? [String: Any],
              let old = before["scope"] as? NSDictionary, let active = final["scope"] as? NSDictionary, active.isEqual(old),
              active["status"] as? String == "PASS",
              let a = before["samples"] as? [[String: Any]], a.count == 2, let b = final["samples"] as? [[String: Any]], b.count == 2,
              let sid = (a[0]["session"] as? NSDictionary)?["securitySessionID"] as? UInt32, sid > 0,
              let topology = a[0]["display"] as? NSDictionary, topology["topologyConfirmed"] as? Bool == true,
              topology["activeCGCount"] as? UInt32 == 1,
              let prior = preflight["permissions"] as? [String: Bool], prior["accessibility"] == true, prior["listenEvent"] == true,
              prior == registered["permissions"] as? [String:Bool],
              let system = registered["system"] as? NSDictionary, system.isEqual(preflight["system"]),
              system["build"] as? String == "26A428", (system["sip"] as? NSDictionary)?["enabled"] as? Bool == true
        else { return false }
        return (a + b).allSatisfy { row in
            guard let session = row["session"] as? NSDictionary, let display = row["display"] as? NSDictionary else { return false }
            return session["qualified"] as? Bool == true && session["securitySessionID"] as? UInt32 == sid && display.isEqual(topology)
        }
    }

    @MainActor static func readScope(challenge: UUID, fixture initialFixture: StageEngineHostScope.Fixture?, channel: StageScopeReply?,
                                    awaitRegistration: Bool = false, enrolledSpacesCycle: Bool = false,
                                    ownSpacesCanary: Bool = false) async -> Int32 {
        let bundle = Bundle.main
        let pid = getpid()
        do {
            let before = try OrdinaryProcessImage.read(pid)
            let signer = try liveSigner(bundle)
            guard getuid() != 0, geteuid() == getuid(), before.executable == bundle.executableURL?.resolvingSymlinksInPath(),
                  try OrdinaryProcessImage.signingDigest(pid) == signer.digest else { return 3 }
            if let channel { try await channel.wait(for: .launch, seconds: 10) }
            let url = bundle.bundleURL.resolvingSymlinksInPath()
            let subject: [String: Any] = [
                "pid": pid, "birth": before.launch, "identifier": bundle.bundleIdentifier ?? "",
                "teamIdentifier": signer.team, "kernelExecutable": before.executable.path,
                "cdhash": signer.digest.map { String(format: "%02x", $0) }.joined(),
                "atDailyInstallPath": url.path == "/Applications/Nearpane.app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "source": bundle.object(forInfoDictionaryKey: "NearpaneStageEngineSourceRevision") as? String ?? "",
                "sourceState": bundle.object(forInfoDictionaryKey: "NearpaneStageEngineSourceState") as? String ?? ""
            ]
            func observation(_ fixture: StageEngineHostScope.Fixture?) async throws -> [String: Any] {
                let permissions = ["accessibility": AXIsProcessTrusted(), "listenEvent": CGPreflightListenEventAccess(),
                                   "postEvent": CGPreflightPostEventAccess(), "screenCapture": CGPreflightScreenCaptureAccess()]
                let scope = await StageEngineHostScope.sample(fixture: fixture)
                guard try OrdinaryProcessImage.read(pid) == before, try OrdinaryProcessImage.signingDigest(pid) == signer.digest else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return ["schema": 2, "abi": np_engine_version(), "challenge": challenge.uuidString, "subject": subject,
                        "permissions": permissions, "permissionSource": "Host/self nonprompt preflight",
                        "system": systemEvidence(), "spaceScope": scope]
            }
            var fixture = initialFixture
            var preflight: [String: Any]?
            if ownSpacesCanary {
                guard channel != nil, !awaitRegistration, !enrolledSpacesCycle, fixture == nil else { return 2 }
                preflight = try await observation(nil)
            }
            if awaitRegistration {
                guard initialFixture == nil, let channel else { return 2 }
                let first = try await observation(nil)
                preflight = first
                try channel.finish(JSONSerialization.data(withJSONObject: first, options: [.sortedKeys]) + Data([10]), preflight: true)
                try await channel.wait(for: .registration, seconds: 14)
                fixture = try enrolledFixture(channel)
            }
            var report = try await observation(fixture)
            if ownSpacesCanary || enrolledSpacesCycle {
                guard let channel else { return 2 }
                let key = ownSpacesCanary ? "installedSpacesCanary" : "installedSpacesFixtureCycle"
                let admitted = ownSpacesCanary ? admitsPhysicalScope(preflight: preflight, current: report)
                    : admitsInstalledCycle(preflight: preflight, registered: report)
                if try !channel.exists(.abort), admitted {
                    report[key] = await InstalledSpacesFixtureCycle.read(challenge: challenge, ownPanelOnly: ownSpacesCanary)
                } else {
                    report[key] = ["status": "BLOCKED", "reason": "hostScopeOrRegistrationChanged", "safeToRollback": true] as [String: Any]
                }
            } else if let fixture {
                guard let scope = report["spaceScope"] as? [String: Any] else { return 3 }
                let summary = scope["scope"] as? [String: Any]
                var ordinary: StageGroupScope?
                var native: UInt64?
                if summary?["status"] as? String == "PASS",
                   let display = (summary?["displayUUID"] as? String).flatMap(UUID.init(uuidString:)),
                   let space = (summary?["spaceUUID"] as? String).flatMap(UUID.init(uuidString:)),
                   let id = summary?["nativeID"] as? UInt64 {
                    ordinary = .init(display: display, nativeSpace: space)
                    native = id
                }
                let guardian = CornerGuardianFixtureReport.sample(pid: fixture.pid, birth: fixture.birth, number: fixture.number,
                    executable: fixture.executable, cdhash: fixture.cdhash, scope: ordinary, nativeID: native)
                report["guardianFixture"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(guardian))
                let independent = await CornerGuardianIndependentProbe.sample(host: guardian, executable: fixture.executable)
                report["guardianIndependent"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(independent))
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            if let channel {
                try channel.finish(data + Data([10]))
            } else {
                try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
            return 0
        } catch { return 3 }
    }

    @MainActor static func run(observeSystem: Bool, challenge: UUID?) async -> Int32 {
        guard let engine = NativeStageWindowEngine() else { return 3 }
        do {
            var results = [[String: Any]]()
            var safe = true
            for (name, id) in [("corner", UInt32(NP_CORNER)), ("spaces", UInt32(NP_SPACES))] {
                let intent = UUID()
                let request = NativeStageEngineRequest(backend: id, operation: UInt32(NP_HIDE), intent: intent,
                    group: UUID(), scope: .init(display: UUID(), nativeSpace: UUID()), member: UUID(),
                    lifetime: UUID(), generation: UUID(), window: .init(pid: .max, birth: 1, number: .max),
                    nativeID: 1, frame: .init(width: 100, height: 100))
                let refused = try await engine.submit(request)
                let rejected = refused.status == NP_UNSUPPORTED && refused.intent == intent && refused.owned == 0
                safe = safe && rejected
                var row: [String: Any] = ["backend": name, "unqualifiedWriteRefused": rejected]
                if observeSystem {
                    let result = try await engine.submit(.init(backend: id, operation: UInt32(NP_PROBE), intent: UUID()))
                    row["readOnlyProbe"] = ["status": result.status, "flags": result.flags, "detail": result.detail]
                }
                results.append(row)
            }
            let closed = await engine.close()
            var report: [String: Any] = ["abi": np_engine_version(), "engines": results, "closed": closed]
            if let challenge { report["challenge"] = challenge.uuidString.lowercased() }
            if observeSystem {
                report["permissions"] = ["accessibility": AXIsProcessTrusted(), "listenEvents": CGPreflightListenEventAccess()]
                report["displays"] = NSScreen.screens.count
            }
            let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: json + Data([10]))
            return safe && closed ? 0 : 3
        } catch {
            engine.revoke()
            _ = await engine.close()
            return 3
        }
    }
}
