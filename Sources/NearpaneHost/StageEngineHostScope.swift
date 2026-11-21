import AppKit
import CNearpaneWindowEngine
import Foundation
import NearpaneCore
import Security

/// Evidence for the explicit read-only Host diagnostic. This never selects a desktop or a window.
enum StageEngineHostScope {
    struct Fixture {
        let pid: Int32
        let birth: UInt64
        let number: UInt32
        let executable: URL
        let cdhash: String
    }

    struct Verdict: Equatable {
        let status: String
        let reason: String
        var json: [String: Any] { ["status": status, "reason": reason] }
    }

    struct Space: Equatable {
        let id64, managedID, kind: UInt64?
        let uuid: UUID?
        let malformed: Bool

        init(_ row: [String: Any]?) {
            id64 = integer(row?["id64"])
            managedID = integer(row?["ManagedSpaceID"])
            kind = integer(row?["type"])
            uuid = nonzeroUUID(row?["uuid"])
            malformed = row == nil || (row?["id64"] != nil && id64 == nil)
                || (row?["ManagedSpaceID"] != nil && managedID == nil)
                || (row?["type"] != nil && kind == nil) || (row?["uuid"] != nil && uuid == nil)
        }

        var number: UInt64? {
            if let id64, let managedID, id64 != managedID { return nil }
            guard let n = id64 ?? managedID, n > 0 else { return nil }
            return n
        }
        var json: [String: Any] {
            ["id64": value(id64), "managedID": value(managedID), "type": value(kind),
             "uuid": value(uuid?.uuidString), "malformed": malformed]
        }
    }

    struct Identity: Equatable {
        let display, space: UUID
        let number: UInt64
    }

    struct Inventory {
        let current: Space
        let matches: [Space]
        let token: String?
        let displayCount, matchingDisplays, spaceCount: Int
        let displayBound: Bool
        let nativeDisplay: UUID?

        init(rows: [[String: Any]]?, display: UUID?, singleMain: Bool) {
            self.nativeDisplay = display
            let selected = (rows ?? []).filter { row in
                guard let display, let token = row["Display Identifier"] as? String else { return false }
                return nonzeroUUID(token) == display || (token == "Main" && singleMain && rows?.count == 1)
            }
            displayCount = rows?.count ?? 0
            matchingDisplays = selected.count
            let raw = selected.count == 1 ? selected.first : nil
            displayBound = raw != nil
            token = raw?["Display Identifier"] as? String
            let active = Space(raw?["Current Space"] as? [String: Any])
            current = active
            let roster = (raw?["Spaces"] as? [[String: Any]])?.map { Space($0) }
            spaceCount = roster?.count ?? 0
            // Both numeric aliases take part, so a row with conflicting aliases cannot disappear from this check.
            matches = active.number.map { n in (roster ?? []).filter { $0.id64 == n || $0.managedID == n } } ?? []
        }

        func evaluate(direct: UInt64?, directAfter: UInt64?) -> (Verdict, Identity?) {
            func stop(_ reason: String, _ status: String = "UNKNOWN") -> (Verdict, Identity?) {
                (.init(status: status, reason: reason), nil)
            }
            guard let display = nativeDisplay, displayBound else { return stop("missingOrAmbiguousDisplay") }
            guard let n = current.number, let direct, let directAfter else { return stop("currentNumberOrDirectReadMissing") }
            guard direct == n, directAfter == n else { return stop("managedAndDirectCurrentDisagree") }
            guard matches.count == 1, let matched = matches.first, matched.number == n else { return stop("missingOrAmbiguousActiveRosterEntry") }
            let exactUUID = !current.malformed && !matched.malformed && current.uuid != nil && current.uuid == matched.uuid
            let observedID = exactUUID ? current.uuid.map { Identity(display: display, space: $0, number: n) } : nil
            if current.kind == 4 || matched.kind == 4 {
                return (.init(status: "BLOCKED", reason: "fullscreenType4"), current.kind == matched.kind ? observedID : nil)
            }
            guard let currentType = current.kind, let rosterType = matched.kind else { return stop("missingSpaceType") }
            guard currentType == rosterType else { return stop("spaceTypesDisagree") }
            guard currentType == 0 else { return stop("activeSpaceIsNotOrdinary", "BLOCKED") }
            guard !current.malformed, !matched.malformed, let u = current.uuid, let m = matched.uuid else {
                return stop("currentOrMatchedUUIDOrIdentityMissing")
            }
            guard u == m else { return stop("currentAndRosterUUIDDisagree") }
            return (.init(status: "PASS", reason: "ordinaryCurrentAndRosterMatchDirect"), .init(display: display, space: u, number: n))
        }
    }

    struct MemberRead: Equatable {
        let verdict: Verdict
        let reverse: [UInt64]?
        let forward: Int32?
        let isOnActiveSpace: Bool?

        init(registered: Bool, bound: Bool, active: UInt64?, reverse: [UInt64]?, forward: Int32?, local: Bool?) {
            self.reverse = registered && bound ? reverse : nil
            self.forward = registered && bound ? forward : nil
            isOnActiveSpace = registered && bound ? local : nil
            if !registered { verdict = .init(status: "NOT_RUN", reason: "noSignedFixtureRegistered") }
            else if !bound { verdict = .init(status: "UNKNOWN", reason: "signedWindowIdentityNotConfirmed") }
            else if let active, let reverse, let forward {
                if reverse.count != Set(reverse).count || forward > 1 {
                    verdict = .init(status: "UNKNOWN", reason: "duplicateMembershipResult")
                } else if reverse == [active] && forward == 1 && local != false {
                    verdict = .init(status: "PASS", reason: "exclusiveReverseAndExactForward")
                } else if reverse == [active] && forward == 1 && local == false {
                    verdict = .init(status: "UNKNOWN", reason: "owningAppKitWindowDisagrees")
                } else if (forward == 1) != reverse.contains(active) {
                    verdict = .init(status: "UNKNOWN", reason: "forwardAndReverseDisagree")
                } else {
                    verdict = .init(status: "FAIL", reason: "notExclusiveToSampledDesktop")
                }
            } else { verdict = .init(status: "UNKNOWN", reason: "membershipOrActiveNumberMissing") }
        }
    }

    struct Continuity: Equatable {
        let pid: Int32
        let birth: UInt64
        let login: UInt32?
        let screens: [String]
        let completeScreen: Bool
        let connection: Int32
        let seqStart, seqEnd: UInt64
        let timeStart, timeEnd: UInt64
    }

    private static func interruption(_ a: Continuity, _ b: Continuity) -> Verdict? {
        guard a.pid > 0, a.pid == b.pid, a.birth > 0, a.birth == b.birth,
              let session = a.login, session == b.login, a.connection > 0, a.connection == b.connection else {
            return .init(status: "UNKNOWN", reason: "hostLoginOrWindowServerConnectionChangedOrMissing")
        }
        guard a.completeScreen, b.completeScreen, !a.screens.isEmpty, a.screens == b.screens else {
            return .init(status: "UNKNOWN", reason: "physicalDisplayTopologyChangedOrUnverified")
        }
        guard a.timeStart <= a.timeEnd, a.timeEnd < b.timeStart, b.timeStart <= b.timeEnd,
              a.seqStart == a.seqEnd, a.seqEnd == b.seqStart, b.seqStart == b.seqEnd else {
            return .init(status: "UNKNOWN", reason: "clockOrActiveSpaceNotificationChanged")
        }
        return nil
    }

    static func pair(_ a: Continuity, _ b: Continuity, _ first: Verdict, _ last: Verdict,
                     _ left: Identity?, _ right: Identity?) -> Verdict {
        if let interrupted = interruption(a,b) { return interrupted }
        guard first.status == "PASS" else { return first }
        guard last.status == "PASS" else { return last }
        guard let left, left == right else { return .init(status: "UNKNOWN", reason: "ordinarySpaceChangedBetweenReads") }
        return .init(status: "PASS", reason: "sameHostLoginScreenAndOrdinarySpaceTwice")
    }

    static func memberPair(_ a: MemberRead, _ b: MemberRead, current: UInt64?, registered: Bool)
        -> (combined: Verdict, forward: Verdict, reverse: Verdict) {
        let unavailable = registered ? Verdict(status: "UNKNOWN", reason: "sameSignedFixtureAndCurrentSpaceNotConfirmed") :
            Verdict(status: "NOT_RUN", reason: "noSignedFixtureRegistered")
        guard registered, let current else { return (unavailable, unavailable, unavailable) }
        let forward: Verdict
        if let x = a.forward, let y = b.forward, x == y, x == 0 || x == 1 {
            forward = .init(status: x == 1 ? "PASS" : "FAIL", reason: x == 1 ? "oneHitInEachSpaceRead" : "absentInBothSpaceReads")
        } else { forward = .init(status: "UNKNOWN", reason: "forwardResultMissingDuplicateOrChanged") }
        let reverse: Verdict
        if let x = a.reverse, let y = b.reverse, x == y, Set(x).count == x.count {
            reverse = .init(status: x == [current] ? "PASS" : "FAIL", reason: x == [current] ? "exclusiveInBothWindowReads" : "notExclusiveInWindowReads")
        } else { reverse = .init(status: "UNKNOWN", reason: "reverseResultMissingDuplicateOrChanged") }
        let combined = a == b ? b.verdict : Verdict(status: "UNKNOWN", reason: "membershipOrOwnerReferenceChanged")
        return (combined, forward, reverse)
    }

    private static func value(_ x: Any?) -> Any { x ?? NSNull() }
    private static func integer(_ x: Any?) -> UInt64? {
        guard let n = x as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(),
              ["c","s","i","l","q","C","S","I","L","Q"].contains(String(cString: n.objCType)),
              n.int64Value >= 0 else { return nil }
        return n.uint64Value
    }
    private static func nonzeroUUID(_ x: Any?) -> UUID? {
        guard let s = x as? String, let id = UUID(uuidString: s), id.uuidString != "00000000-0000-0000-0000-000000000000" else { return nil }
        return id
    }

    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var sequence: UInt64 = 0
        func increment() { lock.withLock { sequence += 1 } }
        var read: UInt64 { lock.withLock { sequence } }
    }

    private struct Physical {
        let main: UUID?
        let single: Bool
        let complete: Bool
        let topology: [String]
        let json: [String: Any]

        @MainActor init() {
            let primary = CGMainDisplayID()
            let screens = NSScreen.screens
            let appKit = screens.compactMap { ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value }
            var count: UInt32 = 0
            var ok = CGGetActiveDisplayList(0, nil, &count) == .success && (1...32).contains(count)
            var ids = [CGDirectDisplayID](repeating: 0, count: ok ? Int(count) : 0), got: UInt32 = 0
            if ok { ok = CGGetActiveDisplayList(count, &ids, &got) == .success && got == count }
            let sorted = ok ? ids.sorted() : []
            var found: [String] = [], descriptors: [[String:Any]] = [], primaryUUID: UUID?
            for id in sorted {
                let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
                let uuid = cf.flatMap { nonzeroUUID(CFUUIDCreateString(nil, $0) as String) }
                let mirrored = CGDisplayIsInMirrorSet(id) != 0
                let active = CGDisplayIsActive(id) != 0 && CGDisplayIsOnline(id) != 0
                if let uuid { found.append("\(id)/\(uuid.uuidString)") }
                if id == primary { primaryUUID = uuid }
                ok = ok && uuid != nil && !mirrored && active
                descriptors.append(["cgID": id, "uuid": value(uuid?.uuidString), "primary": id == primary,
                                    "activeAndOnline": active, "mirrored": mirrored, "builtIn": CGDisplayIsBuiltin(id) != 0])
            }
            complete = ok && screens.count == appKit.count && appKit.sorted() == sorted && Set(sorted).count == sorted.count
                && Set(found.compactMap { $0.split(separator: "/").last }).count == sorted.count && primaryUUID != nil
            main = primaryUUID
            single = complete && sorted.count == 1
            topology = found
            json = ["primaryCGID": primary, "primaryUUID": value(primaryUUID?.uuidString), "activeCGCount": count,
                    "appKitScreenIDs": appKit.sorted(), "cgDisplays": descriptors, "topologyConfirmed": complete]
        }
    }

    private static func session() -> (UInt32?, [String: Any]) {
        var sid: SecuritySessionId = 0
        let status = SessionGetInfo(callerSecuritySession, &sid, nil)
        let console = CGSessionCopyCurrentDictionary() as? [String: Any]
        let sameUser = integer(console?[kCGSessionUserIDKey as String]) == UInt64(getuid())
        let onConsole = console?[kCGSessionOnConsoleKey as String] as? Bool
        let loginDone = console?[kCGSessionLoginDoneKey as String] as? Bool
        let locked = console?["CGSSessionScreenIsLocked"] as? Bool
        let ok = status == errSecSuccess && sid > 0 && sameUser && onConsole == true && loginDone == true && locked != true
        return (ok ? sid : nil, ["securitySessionID": status == errSecSuccess ? value(sid) : NSNull(),
                               "securityStatus": status, "consoleUserMatches": sameUser, "onConsole": value(onConsole),
                               "loginDone": value(loginDone), "screenLocked": value(locked), "qualified": ok])
    }

    /// Check the kernel birth/path and running/disk code before asking the window system about this number.
    /// A caller-supplied path or digest cannot admit a general user application.
    @MainActor private static func belongs(_ f: Fixture, local: NSWindow?) -> Bool {
        guard f.pid > 0, f.birth > 0, f.number > 0, f.executable.isFileURL, f.executable.path.hasPrefix("/"),
              let before = try? OrdinaryProcessImage.read(f.pid), before.launch == f.birth,
              before.executable.resolvingSymlinksInPath().path == f.executable.resolvingSymlinksInPath().path,
              let app = Bundle(url: f.executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()),
              let bundleIdentifier = app.bundleIdentifier, app.executableURL?.resolvingSymlinksInPath().path == before.executable.path else { return false }
        let own = f.pid == getpid()
        if own {
            guard ["com.holdsnow.nearpane.host","com.holdsnow.nearpane.alpha"].contains(bundleIdentifier), let local,
                  local.windowNumber == Int(f.number), NSApp?.window(withWindowNumber: Int(f.number)) === local else { return false }
        } else {
            guard local == nil, ["com.holdsnow.nearpane.engine-fixture.a", "com.holdsnow.nearpane.engine-fixture.b",
                                 "com.holdsnow.nearpane.spaces-launch-canary"].contains(bundleIdentifier) else { return false }
        }
        let rule = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate)
        var requirement: SecRequirement?, live: SecCode?, fixed: SecStaticCode?, image: SecStaticCode?
        func digest(_ code: SecStaticCode) -> String? {
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, .init(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let fields = info as? [String:Any], fields[kSecCodeInfoIdentifier as String] as? String == bundleIdentifier,
                  let bytes = fields[kSecCodeInfoUnique as String] as? Data, bytes.count >= 20 else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String:f.pid] as CFDictionary, [], &live) == errSecSuccess, let live,
              SecCodeCheckValidity(live, strict, requirement) == errSecSuccess,
              SecCodeCopyStaticCode(live, [], &image) == errSecSuccess, let image,
              SecStaticCodeCreateWithPath(app.bundleURL as CFURL, [], &fixed) == errSecSuccess, let fixed,
              SecStaticCodeCheckValidity(fixed, strict, requirement) == errSecSuccess,
              let actual = digest(image), actual == f.cdhash, digest(fixed) == actual,
              let targeted = CGWindowListCopyWindowInfo(.optionIncludingWindow, f.number) as? [[String: Any]], targeted.count == 1,
              integer(targeted[0][kCGWindowNumber as String]) == UInt64(f.number),
              integer(targeted[0][kCGWindowOwnerPID as String]) == UInt64(f.pid),
              (try? OrdinaryProcessImage.read(f.pid)) == before else { return false }
        return true
    }

    private struct Observation {
        let data: [String: Any]
        let continuity: Continuity
        let scope: Verdict
        let identity: Identity?
        let member: MemberRead
    }

    @MainActor private static func read(_ index: Int, _ changes: Changes, _ f: Fixture?, _ local: NSWindow?) -> Observation {
        let start = DispatchTime.now().uptimeNanoseconds, beginSequence = changes.read
        let pid = getpid(), image = try? OrdinaryProcessImage.read(pid), (login, sessionData) = session()
        let display = Physical()
        var conn: Int32 = 0, catalogError: Int32 = 0
        let catalog = np_host_scope_copy_managed(&conn, &catalogError) as? [[String:Any]]
        let i = Inventory(rows: catalog, display: display.main, singleMain: display.single)
        let managedRows: [[String:Any]] = (catalog ?? []).map { row in
            let current = Space(row["Current Space"] as? [String:Any])
            let entries = (row["Spaces"] as? [[String:Any]])?.map { Space($0) } ?? []
            let matched = current.number.map { n in entries.filter { $0.id64 == n || $0.managedID == n } } ?? []
            return ["displayToken": value(row["Display Identifier"] as? String), "current": current.json,
                    "rosterCount": entries.count, "orderedDesktops": entries.map(\.json), "matchingActiveEntries": matched.map(\.json)]
        }
        func direct() -> (UInt64?, Int32?) {
            guard let token = i.token else { return (nil,nil) }
            var err: Int32 = 0
            let n = np_host_scope_direct(conn, token as CFString, &err)
            return (n == 0 || err != 0 ? nil : n, err)
        }
        let (initialDirect, initialError) = direct()
        var inverse: [UInt64]?, forward: Int32?, reverseError: Int32?, forwardError: Int32?, active: Bool?
        let enrolled = f != nil
        var bound = false
        let gated = login != nil && display.complete
        if let f, gated, belongs(f, local: local) {
            var err: Int32 = 0
            if let rows = np_host_scope_reverse(conn, f.number, &err) as? [NSNumber], err == 0 {
                inverse = rows.map(\.uint64Value)
            }
            reverseError = err
            if let n = i.current.number, initialDirect == n {
                let hits = np_host_scope_forward_hits(conn, n, f.number, &err)
                if err == 0 && hits >= 0 { forward = hits }
                forwardError = err
            }
            active = local?.isOnActiveSpace
            bound = belongs(f, local: local)
            if !bound { inverse = nil; forward = nil; active = nil }
        }
        let (endDirect, endError) = direct()
        let (scope, identity) = i.evaluate(direct: initialDirect, directAfter: endDirect)
        let m = MemberRead(registered: enrolled, bound: bound, active: i.current.number, reverse: inverse, forward: forward, local: active)
        let endSequence = changes.read, end = DispatchTime.now().uptimeNanoseconds
        let continuity = Continuity(pid: pid, birth: image?.launch ?? 0, login: login, screens: display.topology,
                                    completeScreen: display.complete, connection: conn, seqStart: beginSequence, seqEnd: endSequence,
                                    timeStart: start, timeEnd: end)
        let appKitReason: String
        if active != nil { appKitReason = "retainedOwningNSWindow" }
        else if f == nil { appKitReason = "noSignedFixtureRegistered" }
        else if f?.pid != pid { appKitReason = "externalFixtureHasNoNSWindowInThisHost" }
        else { appKitReason = "owningNSWindowRegistrationNotConfirmed" }
        let memberJSON: [String: Any] = [
            "registered": enrolled, "boundBeforeAndAfter": bound, "pid": value(bound ? f?.pid : nil),
            "birth": value(bound ? f?.birth : nil), "window": value(bound ? f?.number : nil),
            "windowToSpaces": value(inverse), "windowToSpacesError": value(reverseError),
            "spaceToWindowHitCount": value(forward), "spaceToWindowError": value(forwardError),
            "appKitIsOnActiveSpace": ["status": active == nil ? "NOT_RUN" : "OBSERVED", "value": value(active),
                                      "reason": appKitReason],
            "decision": m.verdict.json]
        let fields: [String: Any] = [
            "sample": index, "hostPID": pid, "hostBirth": value(image?.launch), "startedUptimeNS": start, "endedUptimeNS": end,
            "workspaceSequenceStart": beginSequence, "workspaceSequenceEnd": endSequence, "session": sessionData, "display": display.json,
            "connection": conn, "managedReadError": catalogError, "managedDisplayCount": i.displayCount, "managedRows": managedRows,
            "matchingManagedDisplays": i.matchingDisplays, "managedDisplayToken": value(i.token),
            "rosterCount": i.spaceCount, "current": i.current.json, "matchingRosterEntries": i.matches.map(\.json),
            "directCurrent": value(initialDirect), "directCurrentAfter": value(endDirect),
            "directError": value(initialError), "directErrorAfter": value(endError), "ordinaryIdentity": scope.json, "fixture": memberJSON]
        return Observation(data: fields, continuity: continuity, scope: scope, identity: identity, member: m)
    }

    @MainActor static func sample(fixture: Fixture? = nil, ownedFixtureWindow: NSWindow? = nil) async -> [String: Any] {
        let changes = Changes(), center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { _ in changes.increment() }
        defer { center.removeObserver(observer) }
        let first = read(1, changes, fixture, ownedFixtureWindow)
        do { try await Task.sleep(for: .milliseconds(160)) } catch { /* The cancelled interval cannot qualify. */ }
        let second = read(2, changes, fixture, ownedFixtureWindow)
        let finalSequence = changes.read
        let scoped: Verdict
        if Task.isCancelled { scoped = .init(status: "UNKNOWN", reason: "samplingCancelled") }
        else if finalSequence != second.continuity.seqEnd { scoped = .init(status: "UNKNOWN", reason: "activeSpaceChangedAtEnd") }
        else { scoped = pair(first.continuity, second.continuity, first.scope, second.scope, first.identity, second.identity) }
        let stable = !Task.isCancelled && finalSequence == second.continuity.seqEnd &&
            interruption(first.continuity, second.continuity) == nil && first.identity != nil && first.identity == second.identity
        let checks = memberPair(first.member, second.member, current: stable ? second.identity?.number : nil, registered: fixture != nil)
        var member = checks.combined.json
        member["spaceToWindow"] = checks.forward.json
        member["windowToSpaces"] = checks.reverse.json
        var summary = scoped.json
        if scoped.status == "PASS", let id = second.identity {
            summary["displayUUID"] = id.display.uuidString
            summary["spaceUUID"] = id.space.uuidString
            summary["nativeID"] = id.number
        }
        return ["schema": 1, "readOnly": true, "scope": summary, "fixtureMembership": member,
                "spaceWrites": 0, "windowWrites": 0,
                "workspace": ["notification": "activeSpaceDidChangeNotification", "sequenceReference": "thisObservationOnly",
                              "nativeSpaceIDGetter": "UNAVAILABLE", "notificationsObserved": finalSequence,
                              "isOnActiveSpaceMeaning": "whether the owning NSWindow is on an active Space, never a numeric Space ID"],
                "samples": [first.data,second.data]]
    }
}
