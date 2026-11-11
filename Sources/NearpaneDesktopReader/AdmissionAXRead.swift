import AppKit
import ApplicationServices
import CReadOnlySpaces
import Darwin
import NearpaneCore

/// This reader has no operation for setting an AX value, sending an event or returning a title.
enum AdmissionAXRead {
    enum Failure: Error { case noSession, changedOwner, incompleteList, invalidTarget }

    private static func value(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? v : nil
    }

    static func windowNumber(_ element: AXUIElement) -> UInt32? {
        if let value = value(element, "AXWindowNumber") as? NSNumber,
           let n = UInt32(exactly: value.int64Value), n > 0 { return n }
        let n = NPReadAXWindowNumber(element)
        return n > 0 ? n : nil
    }

    private static func frame(_ element: AXUIElement) -> SurfaceRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return .init(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private static func settable(_ e: AXUIElement, _ key: String) -> Bool? {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(e, key as CFString, &result) == .success ? result.boolValue : nil
    }

    static func observe(_ r: AdmissionReadRequest) throws -> AdmissionReadReply {
        guard r.parent == getppid(), r.pid > 1, r.pid != r.parent, r.pid != getpid(),
              r.targets.count <= 32, Set(r.targets.map(\.number)).count == r.targets.count,
              r.targets.allSatisfy({ $0.number != 0 && ($0.registeredIdentifier == nil || r.bundle == "org.nearpane.lab.NearpaneFixtureWindows") }),
              let login = CGSessionCopyCurrentDictionary() as? [String:Any],
              login[kCGSessionOnConsoleKey as String] as? Bool == true,
              login["CGSSessionScreenIsLocked"] as? Bool != true else { throw Failure.noSession }
        func matchesBundle() -> Bool {
            if let identifier = NSRunningApplication(processIdentifier: r.pid)?.bundleIdentifier {
                return identifier == r.bundle
            }
            // Direct-launched packaged helpers can lack a LaunchServices registration.
            var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(r.pid,&bytes,UInt32(bytes.count)) > 0 else { return false }
            let path = URL(fileURLWithPath: String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self))
            let root = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return root.pathExtension == "app" && Bundle(url:root)?.executableURL?.path == path.path && Bundle(url:root)?.bundleIdentifier == r.bundle
        }
        func checkOwner() throws {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(r.pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_pid == UInt32(r.pid), info.pbi_uid == getuid(),
                  info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec == r.launch,
                  matchesBundle() else { throw Failure.changedOwner }
        }
        try checkOwner()
        let app = AXUIElementCreateApplication(r.pid)
        let permitted = AXIsProcessTrusted()
        if !permitted {
            let denied = r.targets.map { target in
                var s = AdmissionSample(pid: r.pid, launch: r.launch, number: target.number, bundle: r.bundle,
                                        uptime: ProcessInfo.processInfo.systemUptime)
                s.permission = false
                return AdmissionPair(first: s, second: s)
            }
            return .init(nonce: r.nonce, permitted: false, numbers: [], pairs: denied)
        }
        guard AXUIElementSetMessagingTimeout(app, 0.12) == .success else { throw Failure.incompleteList }
        func windows() throws -> [AXUIElement] {
            try checkOwner()
            var array: CFArray?
            guard AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 65, &array) == .success,
                  let rows = array as? [AXUIElement], rows.count <= 64 else { throw Failure.incompleteList }
            for e in rows {
                var pid: pid_t = 0
                guard AXUIElementGetPid(e, &pid) == .success, pid == r.pid,
                      AXUIElementSetMessagingTimeout(e, 0.1) == .success else { throw Failure.changedOwner }
            }
            return rows
        }
        if r.targets.isEmpty {
            let numbers = try windows().map(windowNumber)
            try checkOwner()
            return .init(nonce: r.nonce, permitted: true, numbers: numbers, pairs: [])
        }
        let tokens = r.targets.map { _ in UUID() }
        func sample() throws -> [(AdmissionSample, AXUIElement?)] {
            let entries = try windows().map { ($0, windowNumber($0)) }
            let stage = StageManagerPreference.read()
            return r.targets.enumerated().map { index, target in
                var s = AdmissionSample(pid: r.pid, launch: r.launch, number: target.number, bundle: r.bundle,
                                        uptime: ProcessInfo.processInfo.systemUptime)
                s.permission = true; s.stageManager = stage
                guard entries.filter({ $0.1 == target.number }).count <= 1 else { return (s,nil) }
                let matches = entries.filter { e,n in
                    if let ident = target.registeredIdentifier {
                        // A signed owner independently supplies the identifier/number pair.
                        return (n == nil || n == target.number) && value(e,kAXIdentifierAttribute) as? String == ident
                    }
                    return n == target.number
                }
                guard matches.count == 1, let (e,n) = matches.first else { return (s,nil) }
                s.element = tokens[index]
                s.axNumber = n ?? (target.registeredIdentifier != nil ? target.number : nil)
                s.axFrame = frame(e)
                let role = value(e,kAXRoleAttribute) as? String, subrole = value(e,kAXSubroleAttribute) as? String
                let modal = (value(e,kAXModalAttribute) as? NSNumber)?.boolValue
                // Some apps do not vend AXSheets. Inspect only direct child roles of
                // the selected window, never their values, titles or descendants.
                let hasSheet: Bool?
                if let sheets = value(e,"AXSheets") as? [AXUIElement] { hasSheet = !sheets.isEmpty }
                else if target.registeredIdentifier != nil { hasSheet = false } // the signed owner attests attachedSheet == nil
                else {
                    var children: CFArray?
                    if AXUIElementCopyAttributeValues(e, kAXChildrenAttribute as CFString, 0, 65, &children) == .success,
                       let elements = children as? [AXUIElement], elements.count <= 64 {
                        let roles = elements.compactMap { value($0,kAXRoleAttribute) as? String }
                        hasSheet = roles.contains(kAXSheetRole) ? true : (roles.count == elements.count ? false : nil)
                    } else { hasSheet = nil }
                }
                if let role, let subrole {
                    if role != kAXWindowRole || subrole != kAXStandardWindowSubrole || modal == true || hasSheet == true {
                        s.role = .ineligible
                    } else if hasSheet == false && (modal == false || target.registeredIdentifier != nil) { s.role = .ordinary }
                }
                s.minimized = (value(e,kAXMinimizedAttribute) as? NSNumber)?.boolValue
                s.fullscreen = (value(e,"AXFullScreen") as? NSNumber)?.boolValue
                s.positionSettable = settable(e,kAXPositionAttribute); s.sizeSettable = settable(e,kAXSizeAttribute)
                if let minimum = value(e,"AXMinSize"), CFGetTypeID(minimum) == AXValueGetTypeID() {
                    var size = CGSize.zero
                    if AXValueGetValue(minimum as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 {
                        s.minimum = .init(width: size.width, height: size.height)
                    }
                }
                guard let descriptions = CGWindowListCopyWindowInfo(.optionIncludingWindow,target.number) as? [[String:Any]],
                      descriptions.count == 1, let row = descriptions.first,
                      row[kCGWindowNumber as String] as? UInt32 == target.number,
                      row[kCGWindowOwnerPID as String] as? Int32 == r.pid else { return (s,e) }
                s.layer = row[kCGWindowLayer as String] as? Int
                s.onScreen = row[kCGWindowIsOnscreen as String] as? Bool
                if let raw = row[kCGWindowBounds as String] as? NSDictionary,
                   let rect = CGRect(dictionaryRepresentation: raw), !rect.isEmpty {
                    s.cgFrame = .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
                    var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
                    guard CGGetDisplaysWithRect(rect, UInt32(ids.count), &ids, &count) == .success, count == 1,
                          CGDisplayBounds(ids[0]).contains(rect), CGDisplayIsInMirrorSet(ids[0]) == 0,
                          let uuid = CGDisplayCreateUUIDFromDisplayID(ids[0])?.takeRetainedValue() else { return (s,e) }
                    s.display = CFUUIDCreateString(nil, uuid) as String
                }
                return (s,e)
            }
        }
        let a = try sample()
        Thread.sleep(forTimeInterval: 0.09)
        let b = try sample()
        try checkOwner()
        let pairs = zip(a,b).map { before, after in
            var second = after.0
            if let x = before.1, let y = after.1, !CFEqual(x,y) { second.element = nil }
            return AdmissionPair(first: before.0, second: second)
        }
        return .init(nonce: r.nonce, permitted: permitted, numbers: [], pairs: pairs)
    }
}
