// Compiled with the checked-in independent observer declarations, in a temporary
// executable. The only mutating call in this driver is AXPress on one exact
// button belonging to the installed, running Nearpane sidebar.
struct TrialRefusal: Error { var reason: String; init(_ reason: String) { self.reason = reason } }
struct Member: Decodable {
    let pid: Int32, birth: UInt64, number: UInt32, space: UInt64
    let bundlePath, bundleID, codeHash: String
}
struct TrialScope: Decodable {
    struct Authorized: Decodable { let id: UInt64; let uuid: UUID }
    struct Host: Decodable { let pid: Int32, codeHash: String, launch: Double }
    let host: Host, display: String, spaces: [Authorized], witnesses: [Member], expiresUptime: Double
}
struct PhysicalInput: Equatable {
    let counts: [UInt32]
    init() {
        counts = [CGEventType.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown,
                  .flagsChanged, .scrollWheel, .leftMouseDragged, .rightMouseDragged].map {
            CGEventSource.counterForEventType(.hidSystemState, eventType: $0)
        }
    }
}
var physical = PhysicalInput()
func trialSend(_ object: Object) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
func validateTrial(_ scope: TrialScope, original: [Object], geometry: [Object]) throws -> (NSRunningApplication, [Object], UInt64) {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
        !$0.isTerminated && $0.bundleURL?.standardizedFileURL == installed.standardizedFileURL
    }
    guard scope.expiresUptime > ProcessInfo.processInfo.systemUptime, physical == PhysicalInput(), AXIsProcessTrusted(),
          apps.count == 1, let app = apps.first, app.processIdentifier == scope.host.pid,
          app.launchDate?.timeIntervalSince1970 == scope.host.launch, runningCodeHash(app.processIdentifier) == scope.host.codeHash,
          let session = CGSessionCopyCurrentDictionary() as? Object, session["CGSSessionScreenIsLocked"] as? Bool != true,
          session[kCGSessionOnConsoleKey as String] as? Bool == true,
          (displays() as NSArray).isEqual(to: geometry), let live = inventory(), live.count == original.count,
          let frame = geometry.first(where: { $0["uuid"] as? String == scope.display })?["bounds"] as? [CGFloat],
          frame.count == 4, let pointer = CGEvent(source: nil)?.location,
          CGRect(x:frame[0], y:frame[1], width:frame[2], height:frame[3]).contains(pointer)
    else { throw TrialRefusal("changed Host, input, console, pointer display, permission or topology") }
    var current: UInt64?
    for s in live {
        guard let uuid = s["scope"] as? String,
              let old = original.first(where: { $0["scope"] as? String == uuid }),
              let records = s["records"] as? [Object], let oldRecords = old["records"] as? [Object],
              (records as NSArray).isEqual(to: oldRecords)
        else { throw TrialRefusal("Space order or identity changed") }
        if uuid == scope.display {
            current = s["current"] as? UInt64
            for space in scope.spaces {
                guard records.filter({ $0["id"] as? UInt64 == space.id && $0["type"] as? Int == 0 &&
                    ($0["uuid"] as? String).flatMap(UUID.init(uuidString:)) == space.uuid }).count == 1
                else { throw TrialRefusal("a leased Space was removed or replaced") }
            }
        } else if s["current"] as? UInt64 != old["current"] as? UInt64 { throw TrialRefusal("another display changed Space") }
    }
    guard let current, scope.spaces.contains(where: { $0.id == current }),
          let windows = CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements], kCGNullWindowID) as? [Object]
    else { throw TrialRefusal("current Space escaped scope or CG unavailable") }
#if NATIVE_CONTRACT
    guard let census=NPContractMemberReport(scope.spaces.map { NSNumber(value:$0.id) } as CFArray,app.processIdentifier) as? [String:[String:Any]],
          scope.spaces.allSatisfy({ s in
              guard let entry=census[String(s.id)], entry["unresolved"] as? Int == 0, entry["otherMembers"] as? Int == 0,
                    let rows=entry["ordinary"] as? [[String:NSNumber]] else {return false}
              return rows.count == scope.witnesses.filter({$0.space==s.id}).count && rows.allSatisfy({ r in
                  scope.witnesses.contains { $0.space==s.id && $0.pid==r["pid"]?.int32Value && $0.number==r["number"]?.uint32Value }
              })
          }) else {throw TrialRefusal("per-Space membership no longer limited to fixtures")}
#else
    let trialOccupancy = occupancy(windows, excluding: app.processIdentifier)
    guard trialOccupancy["unresolved"] as? Int == 0, let counts = trialOccupancy["counts"] as? [String:Int],
          scope.spaces.allSatisfy({ s in counts[String(s.id), default:0] == scope.witnesses.filter { $0.space == s.id }.count })
    else { throw TrialRefusal("window inventory no longer limited to witnesses") }
#endif
    for w in scope.witnesses {
        var b = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: b))
        guard proc_pidinfo(w.pid, PROC_PIDTBSDINFO, 0, &b, size) == size, b.pbi_pid == UInt32(w.pid), b.pbi_uid == getuid(),
              b.pbi_start_tvsec * 1_000_000 + b.pbi_start_tvusec == w.birth else {
            throw TrialRefusal("fixture PID or process birth changed: \(w.pid)")
        }
        let identities=["net.example.spaces-document":"Field Notes.app","net.example.spaces-route-witness":"Route Notes.app"]
        guard identities[w.bundleID]==URL(fileURLWithPath:w.bundlePath).lastPathComponent else {
            throw TrialRefusal("unenrolled fixture bundle identity: \(w.pid)")
        }
        var bytes=[CChar](repeating:0,count:4096)
        guard proc_pidpath(w.pid,&bytes,UInt32(bytes.count))>0 else {throw TrialRefusal("fixture kernel path unavailable: \(w.pid)")}
        let executable=URL(fileURLWithPath:String(cString:bytes)).resolvingSymlinksInPath().standardizedFileURL
        let expected=URL(fileURLWithPath:w.bundlePath).appendingPathComponent("Contents/MacOS/FieldNotes").resolvingSymlinksInPath().standardizedFileURL
        guard executable==expected else {throw TrialRefusal("fixture kernel executable differs from enrolled file: \(w.pid)")}
        guard Bundle(url:URL(fileURLWithPath:w.bundlePath))?.bundleIdentifier==w.bundleID else {
            throw TrialRefusal("fixture's signed bundle identifier differs: \(w.pid)")
        }
        guard runningCodeHash(w.pid)==w.codeHash else {throw TrialRefusal("fixture CDHash changed: \(w.pid)")}
        guard (NPReadWindowSpaces(w.number) as? [UInt64]) == [w.space] else {
            throw TrialRefusal("reverse membership changed for fixture window \(w.number) on \(w.space)")
        }
#if !NATIVE_CONTRACT
        // The standalone legacy observer lacks the per-Space owner census used above.
        guard windows.filter({ $0[kCGWindowNumber as String] as? UInt32 == w.number &&
                               $0[kCGWindowOwnerPID as String] as? Int32 == w.pid }).count==1 else {
            throw TrialRefusal("public window owner unavailable: \(w.number)")
        }
#endif
    }
#if !NATIVE_CONTRACT
    let foreground = NSWorkspace.shared.frontmostApplication
    let focused = focusedNumber(foreground?.processIdentifier)
    let focusedTest = scope.witnesses.contains { $0.pid == foreground?.processIdentifier && $0.number == focused }
    var finderFocus: CFTypeRef?
    let emptyFinder = !scope.witnesses.contains(where: { $0.space == current }) &&
        foreground?.bundleIdentifier == "com.apple.finder" && foreground.map {
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication($0.processIdentifier),
                                          kAXFocusedWindowAttribute as CFString, &finderFocus) == .noValue
        } == true
    guard focusedTest || emptyFinder else { throw TrialRefusal("foreground is outside controlled windows") }
#endif
    // The contract driver sends AXPress only to a verified installed Host row. The
    // scoped census and independently checked source cover even a genuinely empty
    // target, where macOS need not nominate a focused window.
    return (app, windows, current)
}
if let line = readLine(), let scope = try? JSONDecoder().decode(TrialScope.self, from: Data(line.utf8)),
   let envelope = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? Object,
   let original = envelope["baselineScopes"] as? [Object], let geometry = envelope["baselineDisplays"] as? [Object] {
    while let message = readLine() {
        var attempts: [Object] = []
        do {
            physical = PhysicalInput()
            guard let input = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? Object,
                  let targets = input["targets"] as? [UInt64], targets.count <= 5,
                  let allowedSources = input["sources"] as? [UInt64]
            else { throw TrialRefusal("invalid row sequence") }
            var accepted = Set(allowedSources)
            guard accepted.isSubset(of: Set(scope.spaces.map(\.id))) else { throw TrialRefusal("unauthorized source") }
            if targets.isEmpty {
                guard accepted.contains(try validateTrial(scope, original: original, geometry: geometry).2)
                else { throw TrialRefusal("target changed after independent stable readback") }
            }
            for n in targets {
                let (owner, windows, current) = try validateTrial(scope, original: original, geometry: geometry)
                let records = original.first { $0["scope"] as? String == scope.display }?["records"] as? [Object]
                let order = records?.compactMap { $0["id"] as? UInt64 } ?? []
                let leased = Set(scope.spaces.map(\.id))
                guard leased.contains(n), accepted.contains(current), let start = order.firstIndex(of: current),
                      let end = order.firstIndex(of: n),
                      order[min(start,end)...max(start,end)].allSatisfy(leased.contains) else {
                    throw TrialRefusal("unexpected or unleased input endpoint")
                }
                let id = "native-space-row:" + scope.display + ":" + String(n)
                let sidebar = Sidebar(owner, rows: windows)
                guard let nodes = sidebar.controls[id], nodes.count == 1, let button = nodes.first,
                      value(button, kAXEnabledAttribute) as? Bool == true,
                      value(button, kAXRoleAttribute) as? String == kAXButtonRole,
                      value(button, kAXIdentifierAttribute) as? String == id
                else { throw TrialRefusal("exact production row is absent or disabled") }
                var ownerPID: pid_t = 0
                guard AXUIElementGetPid(button, &ownerPID) == .success, ownerPID == owner.processIdentifier,
                      try validateTrial(scope, original: original, geometry: geometry).2 == current
                else { throw TrialRefusal("target changed immediately before AXPress") }
                let t = ProcessInfo.processInfo.systemUptime
                trialSend(["stage":"before-press","target":n,"source":current,"id":id,"t":t])
                let err = AXUIElementPerformAction(button, kAXPressAction as CFString)
                attempts.append(["target":n, "source":current, "id":id, "tPress":t, "axError":err.rawValue])
                trialSend(["stage":"after-press","target":n,"source":current,"id":id,"axError":err.rawValue])
                guard err == .success else { throw TrialRefusal("AXPress returned an error; no retry") }
                // During a rapid group the compositor may already show an intermediate leased desktop.
                accepted.formUnion(order[min(start,end)...max(start,end)])
            }
            trialSend(["ok":true,"attempts":attempts])
        } catch {
            trialSend(["ok":false,"attempts":attempts,"reason":(error as? TrialRefusal)?.reason ?? "observer failure"])
            break
        }
    }
}
