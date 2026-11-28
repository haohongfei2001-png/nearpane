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

    static func command(_ file: URL, _ args: [String]) -> (status: Int32, data: Data) {
        let p = Process(), pipe = Pipe()
        p.executableURL = file
        p.arguments = args
        p.standardOutput = pipe
        do { try p.run() } catch { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
    static func output(_ file: URL, _ args: [String]) -> Data? {
        let reply = command(file, args)
        return reply.status == 0 ? reply.data : nil
    }

    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("overview witness: " + String(describing:error) + "\n").utf8))
            exit(2)
        }
    }

    @MainActor private static func run() async throws {
        let supplement = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--include-fullscreen-diagnostic"
        let passive = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--observe-only"
        guard CommandLine.arguments.count == 2 || supplement || passive else { throw Refusal.invocation }
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
        if passive { result["stage"] = "passiveReadOnly"; result["status"] = "NOT_RUN" }
        let trace = StageOverviewFocusTrace()
        result["clockStart"] = StageOverviewFocusTrace.clock()
        let file = dir.appendingPathComponent("p0.json")
        func save() throws { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:file,options:.atomic) }
        var telemetry = [[String:Any]]()
        do {
            guard version == "27.0", build == "26A428", sip == "System Integrity Protection status: enabled." else { throw Refusal.invocation }
            let (original,subject) = try host()
            result["host"] = subject
            let readHost: (String) async -> Void = { phase in
                let t = ProcessInfo.processInfo.systemUptime
                var r: [String:Any] = ["phase":phase,"startUptime":t]
                let expected = phase == "presented" ? 1 : 0
                let deadline = ContinuousClock.now + .milliseconds(1250)
                var attempts = [[String:Any]]()
                repeat {
                    let begin = ProcessInfo.processInfo.systemUptime
                    let path = base.appendingPathComponent("metrics"), targetPID = original.pid
                    let reply = await Task.detached { command(path,[String(targetPID),"--overview-read"]) }.value
                    var sample: [String:Any] = ["uptime":begin, "endUptime":ProcessInfo.processInfo.systemUptime,
                        "targetPID":targetPID,"targetBirth":original.launch,"exit":reply.status,
                        "source":"installedHostPreviewMetrics","status":"unavailable"]
                    if reply.status == 0, let metrics = (try? JSONSerialization.jsonObject(with:reply.data)) as? [String:Any],
                       metrics["pid"] as? Int32 == targetPID, metrics["missionControlObservation"] is String,
                       let value = metrics["missionControlPresented"] as? Int, [-1,0,1].contains(value) {
                        sample["status"] = value == -1 ? "unknown" : "observed"
                        for key in ["pid","missionControlPresented","missionControlObservation"] { sample[key] = metrics[key] }
                        for key in ["missionControlSample","missionControlReadStartUptime","missionControlReadEndUptime"] { sample[key] = metrics[key] }
                        if let start = metrics["missionControlReadStartUptime"] as? Double,
                           let end = metrics["missionControlReadEndUptime"] as? Double, let received = sample["endUptime"] as? Double {
                            let lower = metrics["missionControlSample"] as? String == "requested" ? begin : t
                            sample["withinPhase"] = lower <= start && start <= end && end <= received
                        }
                    }
                    attempts.append(sample)
                    for key in ["pid","missionControlPresented","missionControlObservation"] { r[key] = sample[key] }
                    r["withinPhase"] = sample["withinPhase"] as? Bool ?? false
                    if (sample["missionControlPresented"] as? Int == expected && r["withinPhase"] as? Bool == true) || passive { break }
                    if attempts.count < 5 && ContinuousClock.now < deadline { try? await Task.sleep(for:.milliseconds(80)) }
                } while attempts.count < 5 && ContinuousClock.now < deadline
                r["attempts"] = attempts
                r["endUptime"] = ProcessInfo.processInfo.systemUptime
                telemetry.append(r)
            }
            let media = OverviewMedia(dir)
            if passive {
                result["hidBeforePassiveRead"] = StageCanaryOverview.hid()
                result["buttonsBefore"] = NSEvent.pressedMouseButtons
                result["inputAvailableBefore"] = StageCanaryOverview.inputAvailable()
                result["scope"] = await StageEngineHostScope.sample()["scope"]
                let focus = StageCanaryOverview.beginFocusObservation()
                result["admission"] = focus.first
                trace.sample("passive")
                await readHost("passive")
                result["sameHostAtEnd"] = try host().0 == original
                result["terminalScope"] = await StageEngineHostScope.sample()["scope"]
                result["terminalAdmission"] = focus.finish()
                result["buttonsAfter"] = NSEvent.pressedMouseButtons
                result["inputAvailableAfter"] = StageCanaryOverview.inputAvailable()
                result["hidAfterPassiveRead"] = StageCanaryOverview.hid()
                result["terminalReadbackUptime"] = ProcessInfo.processInfo.systemUptime
                result["reason"] = "passiveObservationWithoutPresentation"
            } else {
                var admissions = [[String:Any]]()
                var initial = [String:Any]()
                let deadline = ContinuousClock.now + .seconds(360)
                var ready = false, fullscreenOnly = false
                var lastInput: [UInt32]?, lastAdmittedScope: NSDictionary?
                var eligibleSince: TimeInterval?, lastFocus: [UInt64]?
                var lastReason = ""
                var sampleCounts = [String:Int](), maximumIdle = [String:Double]()
                var lastAdmission = [String:Any]()
                repeat {
                    initial = await StageEngineHostScope.sample()
                    let scope = initial["scope"] as? [String:Any] ?? [:]
                    var admission = StageCanaryOverview.admission()
                    admission["nativeScope"] = scope
                    fullscreenOnly = supplement && StageCanaryOverview.fullscreenReadOnlyIdentity(initial) != nil
                    let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType:CGEventType(rawValue:UInt32.max)!)
                    let hid = StageCanaryOverview.hid(), buttons = NSEvent.pressedMouseButtons
                    let now = ProcessInfo.processInfo.systemUptime
                    let focus = ["workspacePID","birth","cgWindowID"].compactMap { (admission[$0] as? NSNumber)?.uint64Value }
                    let ordinary = scope["status"] as? String == "PASS" || fullscreenOnly
                    let eligible = ordinary && admission["reason"] == nil && focus.count == 3 && idle.isFinite && idle >= 2 && buttons == 0 && StageCanaryOverview.inputAvailable()
                    if !eligible || eligibleSince == nil || lastInput != hid || lastFocus != focus || lastAdmittedScope != scope as NSDictionary {
                        eligibleSince = eligible ? now : nil
                    }
                    ready = eligible && eligibleSince.map { now - $0 >= 2 } == true
                    lastInput = hid; lastFocus = focus; lastAdmittedScope = scope as NSDictionary
                    let reason = !ordinary ? (scope["reason"] as? String ?? "ordinaryDesktopUnavailable") :
                        (admission["reason"] as? String ?? (!eligible ? "waitingForIdleInput" : ready ? "ready" : "waitingForStableFocusAndInput"))
                    admission["idleSeconds"] = idle.isFinite ? idle as Any : NSNull(); admission["hid14"] = hid
                    admission["pressedButtons"] = buttons; admission["admissionState"] = reason
                    sampleCounts[reason, default:0] += 1
                    if idle.isFinite { maximumIdle[reason] = max(maximumIdle[reason] ?? 0, idle) }
                    lastAdmission = admission
                    if admissions.isEmpty || lastReason != reason ||
                        admissions.last?["workspacePID"] as? Int32 != admission["workspacePID"] as? Int32 ||
                        (admissions.last?["nativeScope"] as? NSDictionary) != (scope as NSDictionary) || ready {
                        admissions.append(admission)
                    }
                    lastReason = reason
                    if !ready && AXIsProcessTrusted() { try await Task.sleep(for:.milliseconds(700)) }
                } while !ready && AXIsProcessTrusted() && ContinuousClock.now < deadline
                result["admissionReads"] = admissions
                result["admissionSampling"] = ["counts":sampleCounts, "maximumIdleSeconds":maximumIdle,
                                                "last":lastAdmission] as [String:Any]
                result["scope"] = initial["scope"]
                if !ready {
                    result["reason"] = lastReason
                    trace.sample("admissionEnded")
                }
                else {
                    await media.start()
                    let final = await StageEngineHostScope.sample()
                    result["scopeImmediatelyBeforeOverview"] = final["scope"]
                    let stage = fullscreenOnly ? "fullscreenPositionDiagnostic" : "beforeWindowWrites"
                    let observed = await StageCanaryOverview.measure(initial:initial,final:final,stage:stage,trace:trace,
                        cancelled:{ (try? OrdinaryProcessImage.read(original.pid)) != original || NSRunningApplication.runningApplications(withBundleIdentifier:id).map(\.processIdentifier) != [original.pid] },
                        notify:{ await readHost($0) })
                    result["measurement"] = observed
                    result["media"] = await media.finish()
                    let expected = [("before",0,"signedDockAXListWithoutMC"),("presented",1,"signedDockMCIdentifier"),("dismissed",0,"signedDockAXListWithoutMC"),("terminal",0,"signedDockAXListWithoutMC")]
                    let sequence = expected.allSatisfy { phase, value, source in
                        telemetry.filter{ $0["phase"] as? String == phase && $0["pid"] as? Int32 == original.pid &&
                            $0["missionControlPresented"] as? Int == value && $0["missionControlObservation"] as? String == source &&
                            $0["withinPhase"] as? Bool == true }.count == 1
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
            }
        } catch { result["reason"] = "physicalSourceUnavailable/" + String(describing:error) }
        result["clockEnd"] = StageOverviewFocusTrace.clock()
        result["workspaceTimeline"] = trace.receipt()
        result["workspaceDidActivate"] = trace.activations
        result["hostTelemetry"] = telemetry
        result["endedUTC"] = utc.string(from:Date())
        try save()
        print(String(describing:result["status"] ?? "UNKNOWN"),String(describing:result["reason"] ?? ""))
    }
}
