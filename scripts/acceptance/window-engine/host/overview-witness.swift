import AppKit
import CryptoKit
import Foundation
import NearpaneCore
import Security

@main struct OverviewWitness {
    enum Refusal: Error { case invocation, identity }
    private static let id = "com.holdsnow.nearpane.alpha"
    private static let package = URL(fileURLWithPath:"/Applications/Nearpane.app")

    @MainActor static func host() throws -> (OrdinaryProcessImage, [String:Any]) {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier:id)
        guard instances.count == 1, let app = instances.first, app.bundleURL?.standardizedFileURL == package,
              !app.isTerminated, let bundle = Bundle(url:package),
              let source = bundle.object(forInfoDictionaryKey:"NearpaneSourceRevision") as? String else { throw Refusal.identity }
        let image = try OrdinaryProcessImage.read(app.processIdentifier)
        var code: SecStaticCode?, rule: SecRequirement?, info: CFDictionary?
        let requirement = "anchor apple generic and identifier \"com.holdsnow.nearpane.alpha\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard image.executable.path == package.appendingPathComponent("Contents/MacOS/NearpaneHost").path,
              SecStaticCodeCreateWithPath(package as CFURL,[],&code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString,[],&rule) == errSecSuccess,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),rule) == errSecSuccess,
              SecCodeCopySigningInformation(code,.init(rawValue:kSecCSSigningInformation),&info) == errSecSuccess,
              let digest = (info as? [String:Any])?[kSecCodeInfoUnique as String] as? Data,
              try OrdinaryProcessImage.signingDigest(image.pid) == digest,
              try OrdinaryProcessImage.read(image.pid) == image else { throw Refusal.identity }
        return (image, ["pid":image.pid,"birth":image.launch,"cdhash":digest.map{String(format:"%02x",$0)}.joined(),
                         "source":source,"path":image.executable.path,"bundle":id,"team":"ZB9D4T66QB"])
    }

    static func output(_ file: URL, _ args: [String]) -> Data? {
        let p = Process(), pipe = Pipe()
        p.executableURL = file
        p.arguments = args
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    @MainActor static func main() async throws {
        let supplement = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--include-fullscreen-diagnostic"
        guard CommandLine.arguments.count == 2 || supplement else { throw Refusal.invocation }
        umask(0o077)
        let dir = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let base = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        var st = stat()
        var resolved = [CChar](repeating:0,count:Int(PATH_MAX))
        guard dir.path.hasPrefix("/private/tmp/"), realpath(dir.path,&resolved) != nil,
              String(cString:resolved) == dir.path,
              lstat(dir.path,&st) == 0, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700,
              try FileManager.default.contentsOfDirectory(atPath:dir.path).isEmpty else { throw Refusal.invocation }
        let utc = ISO8601DateFormatter(), started = Date()
        func system(_ path: String,_ args: [String]) -> String { String(data:output(URL(fileURLWithPath:path),args) ?? Data(),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "" }
        let build = system("/usr/bin/sw_vers",["-buildVersion"]), version = system("/usr/bin/sw_vers",["-productVersion"])
        let sip = system("/usr/bin/csrutil",["status"])
        var result: [String:Any] = ["schema":1,"stage":"physicalP0BeforeWrites","startedUTC":utc.string(from:started),
            "build":build,"systemVersion":version,"sip":sip,"status":"BLOCKED","hostRole":"runningRegularInstalledHost",
            "observerSHA256":SHA256.hash(data:try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]))).map { String(format:"%02x",$0) }.joined(),
            "observerAXTrusted":AXIsProcessTrusted(),"windowWrites":0,"spaceWrites":0,"launchedHosts":0]
        let file = dir.appendingPathComponent("p0.json")
        func save() throws { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:file,options:.atomic) }
        var telemetry = [[String:Any]]()
        do {
            guard version == "27.0", build == "26A428", sip == "System Integrity Protection status: enabled." else { throw Refusal.invocation }
            let (original,subject) = try host()
            result["host"] = subject
            let readHost: (String) -> Void = { phase in
                let t = ProcessInfo.processInfo.systemUptime
                var r: [String:Any] = ["phase":phase,"startUptime":t]
                if let data = output(base.appendingPathComponent("metrics"),[String(original.pid)]),
                   let metrics = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                    for key in ["pid","missionControlPresented","missionControlObservation"] { r[key] = metrics[key] }
                }
                r["endUptime"] = ProcessInfo.processInfo.systemUptime
                telemetry.append(r)
            }
            let media = OverviewMedia(dir)
            var admissions = [[String:Any]]()
            var initial = [String:Any]()
            let deadline = ContinuousClock.now + .seconds(360)
            var ready = false, fullscreenOnly = false
            repeat {
                initial = await StageEngineHostScope.sample()
                let scope = initial["scope"] as? [String:Any] ?? [:]
                var admission = StageCanaryOverview.admission()
                admission["nativeScope"] = scope
                fullscreenOnly = supplement && StageCanaryOverview.fullscreenReadOnlyIdentity(initial) != nil
                let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType:CGEventType(rawValue:UInt32.max)!)
                ready = (scope["status"] as? String == "PASS" || fullscreenOnly) && admission["reason"] == nil && idle >= 2
                if admissions.isEmpty || admissions.last?["reason"] as? String != admission["reason"] as? String ||
                    admissions.last?["workspacePID"] as? Int32 != admission["workspacePID"] as? Int32 ||
                    (admissions.last?["nativeScope"] as? NSDictionary) != (scope as NSDictionary) || ready {
                    admissions.append(admission)
                }
                if !ready && AXIsProcessTrusted() { try await Task.sleep(for:.milliseconds(700)) }
            } while !ready && AXIsProcessTrusted() && ContinuousClock.now < deadline
            result["admissionReads"] = admissions
            result["scope"] = initial["scope"]
            if !ready { result["reason"] = admissions.last?["reason"] ?? (initial["scope"] as? [String:Any])?["reason"] ?? "ordinaryFocusPairUnavailable" }
            else {
                await media.start()
                let final = await StageEngineHostScope.sample()
                result["scopeImmediatelyBeforeOverview"] = final["scope"]
                let stage = fullscreenOnly ? "fullscreenPositionDiagnostic" : "beforeWindowWrites"
                let observed = await StageCanaryOverview.measure(initial:initial,final:final,stage:stage,
                    cancelled:{ (try? OrdinaryProcessImage.read(original.pid)) != original || NSRunningApplication.runningApplications(withBundleIdentifier:id).map(\.processIdentifier) != [original.pid] },
                    notify:{ readHost($0) })
                readHost("terminal")
                result["measurement"] = observed
                result["media"] = await media.finish()
                let expected = [("before",0,"signedDockAXListWithoutMC"),("presented",1,"signedDockMCIdentifier"),("dismissed",0,"signedDockAXListWithoutMC")]
                let sequence = expected.allSatisfy { phase, value, source in
                    telemetry.filter{ $0["phase"] as? String == phase && $0["pid"] as? Int32 == original.pid &&
                        $0["missionControlPresented"] as? Int == value && $0["missionControlObservation"] as? String == source }.count == 1
                }
                let same = try host().0 == original
                result["hostSequenceConfirmed"] = sequence
                result["sameHostAtEnd"] = same
                let measured = observed["status"] as? String ?? "UNKNOWN"
                result["status"] = measured == "PASS" && (!sequence || !same) ? "UNKNOWN" : measured
                result["reason"] = measured == "PASS" && (!sequence || !same) ? "hostSequenceOrIdentityUnconfirmed" : observed["reason"]
                if fullscreenOnly {
                    result["componentStatus"] = result["status"]
                    result["componentReason"] = result["reason"]
                    result["status"] = "BLOCKED"
                    result["reason"] = "fullscreenObservationCannotAdmitOrdinaryDesktop"
                }
            }
        } catch { result["reason"] = "physicalSourceUnavailable/" + String(describing:error) }
        result["hostTelemetry"] = telemetry
        result["endedUTC"] = utc.string(from:Date())
        try save()
        print(String(describing:result["status"] ?? "UNKNOWN"),String(describing:result["reason"] ?? ""))
    }
}
