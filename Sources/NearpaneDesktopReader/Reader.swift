import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import NearpaneCore
import WindowGeometryCore
import CReadOnlySpaces

@MainActor
struct Reader {
    let request: DesktopReadRequest
    let clock = ProcessInfo.processInfo
    let windowLimit = 192
    #if NEARPANE_ISOLATED_GUI_LAB
    // Scope-only console fixtures can report type evidence from this very read,
    // without another trip to WindowServer or changing the product wire format.
    var scopeTypes: (([String: [String]]) -> Void)?
    #endif

    private func titleToken(_ title: String) -> String? {
        guard !title.isEmpty else { return nil }
        return SHA256.hash(data: Data((request.session.uuidString + title).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func incarnation(_ pid: Int32) -> ProcessIdentity {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_pid == UInt32(pid),
              info.pbi_start_tvsec > 0 else { return .init(pid: pid, launchEpochMicroseconds: nil) }
        return .init(pid: pid, launchEpochMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

    struct List: Equatable {
        var windows: [CGWindowMetadata] = []
        var limited = false
        var backgroundCollectionComplete = false
        var census: CatalogCensusFacts.Sample?
        var audit = [UInt32: [String: Bool]]()
        var orderedAcrossSpaces = Set<UInt32>()
        var observedAcrossSpaces: Set<UInt32>?
        var observedOnscreen: Set<UInt32>?
        var unhiddenOwners = Set<Int32>()
    }

    func windowList(overview: Bool = false, backgroundInventory: SpaceInventory? = nil) throws -> List {
        let fixture = request.fixtureWindows.map(Set.init), anchors = Set(request.anchors.map(\.number))
        let requested = fixture.map { $0.union(anchors) }
        let descriptions: CFArray?
        if let requested {
            guard !requested.isEmpty else { return List() }
            descriptions = NPReadVisibleWindowDescriptions(Array(requested), Int32(requested.count))
        } else {
            descriptions = CGWindowListCopyWindowInfo([overview ? .optionAll : .optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        }
        guard var list = descriptions as? [[String: Any]] else { throw DesktopActionError.unsupported }
        var result = List()
        if overview {
            result.census = .init()
            result.census?.publicRows = list.count
        }
        let requestedAudit = Array((request.sidebarAuditWindows ?? []).prefix(2))
        func auditRows(_ name: String, in rows: [[String: Any]]) {
            for w in requestedAudit {
                let matching = rows.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == w.number }
                result.audit[w.number, default: [:]][name] = matching?[kCGWindowOwnerPID as String] as? Int32 == w.pid
            }
        }
        if overview {
            auditRows("publicCG", in: list)
            // IsOnscreen is an optional CG dictionary key. A separate complete
            // onscreen enumeration supplies negative visibility evidence without
            // treating a missing key as false.
            if let onscreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
                let numbers = onscreen.compactMap { $0[kCGWindowNumber as String] as? NSNumber }
                if numbers.count == onscreen.count { result.observedOnscreen = Self.windowNumberSet(numbers) }
            }
            // The WindowServer enumeration and AppKit's ordered window numbers are
            // independent during a stage transition. Resolve a missing number against
            // its own CG record; never infer its owner or Space from another window.
            let known = Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
            result.observedAcrossSpaces = Self.windowNumberSet(NSWindow.windowNumbers(options: [.allApplications, .allSpaces]))
            result.orderedAcrossSpaces = result.observedAcrossSpaces ?? []
            for id in result.orderedAcrossSpaces.subtracting(known) {
                if let exact = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
                   exact.count == 1, exact[0][kCGWindowNumber as String] as? UInt32 == id {
                    list.append(exact[0])
                }
            }
            if let backgroundInventory {
                let publicRows=Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
                let background=Self.backgroundRows(in:backgroundInventory,known:publicRows)
                auditRows("addedBySpaceLookup", in: background.rows)
                list.append(contentsOf:background.rows)
                result.backgroundCollectionComplete=background.complete
            }
        }
        if overview {
            for w in requestedAudit {
                var flags = result.audit[w.number] ?? [:]
                let row = list.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == w.number &&
                    $0[kCGWindowOwnerPID as String] as? Int32 == w.pid }
                flags["sameProcessBirth"] = incarnation(w.pid).launchEpochMicroseconds == w.birth
                flags["appKitAllSpaces"] = result.orderedAcrossSpaces.contains(w.number)
                flags["rowFound"] = row != nil
                if let row {
                    flags["rowLayerZero"] = row[kCGWindowLayer as String] as? Int == 0
                    flags["rowDrawn"] = (row[kCGWindowAlpha as String] as? Double ?? 0) > 0
                    flags["rowHasBounds"] = row[kCGWindowBounds as String] is NSDictionary
                }
                result.audit[w.number] = flags
            }
        }
        var seen = Set<UInt32>(), allowed = [Int32: Bool](), processes = [Int32: ProcessIdentity]()
        result.census?.expandedRows = list.count
        for row in list {
            guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0,
                  let number = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value, number != 0,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  overview || (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0 else { continue }
            result.census?.eligibleSurfaceRows += 1
            if let fixture {
                guard pid == request.parentPID, fixture.contains(number) || anchors.contains(number) else { continue }
            } else if pid == request.parentPID {
                guard anchors.contains(number) else {
                    result.census?.parentExcludedRows += 1
                    continue
                }
            } else {
                if allowed[pid] == nil {
                    let app = NSRunningApplication(processIdentifier: pid)
                    if overview, app?.isHidden == false { result.unhiddenOwners.insert(pid) }
                    let id = app?.bundleIdentifier?.lowercased() ?? ""
                    let regular = app?.activationPolicy == .regular
                    allowed[pid] = regular && !id.isEmpty && !id.hasPrefix("com.holdsnow.nearpane")
                        && (!overview || !id.hasPrefix("org.nearpane."))
                        && !["com.apple.dock","com.apple.windowmanager","com.apple.loginwindow"].contains(id)
                    if overview {
                        result.census?.ownersChecked += 1
                        if allowed[pid] == true { result.census?.ownersAccepted += 1 }
                        else if app == nil { result.census?.ownersUnavailable += 1 }
                        else if !regular { result.census?.ownersNotRegular += 1 }
                        else if id.isEmpty { result.census?.ownersMissingBundle += 1 }
                        else { result.census?.ownersExcludedBundle += 1 }
                    }
                }
                guard allowed[pid] == true else {
                    result.census?.ownerRejectedRows += 1
                    continue
                }
            }
            guard seen.insert(number).inserted, let fields = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: fields) else { throw GeometryError.invalidGeometry }
            let frame = Rect(rect.minX, rect.minY, rect.width, rect.height)
            guard frame.isValid, !overview || min(frame.width, frame.height) > 1 else { continue }
            guard result.windows.count < (overview ? 4096 : windowLimit) else { result.limited = true; break }
            let process = processes[pid] ?? incarnation(pid); processes[pid] = process
            let reportedOnscreen: Bool?
            if let value = row[kCGWindowIsOnscreen as String], CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                reportedOnscreen = (value as? NSNumber)?.boolValue
            } else { reportedOnscreen = nil }
            result.windows.append(CGWindowMetadata(process: process, windowID: number,
                title: overview ? nil : (row[kCGWindowName as String] as? String).flatMap(titleToken), frame: frame,
                isOnscreen: reportedOnscreen,
                frontToBackIndex: result.windows.count))
        }
        result.census?.acceptedWindows = result.windows.count
        return result
    }

    private struct ReadAX {
        var values = [Int32: [AXWindowMetadata]]()
        var fullScreen = [UUID: Bool]()
        var status: AXReadStatus = .available
    }

    private func accessibility(_ windows: [CGWindowMetadata], deadline: Double) -> ReadAX {
        var result = ReadAX()
        guard AXIsProcessTrusted() else { result.status = .denied; return result }
        let reader = AXMetadataReader(titleToken: titleToken)
        var seen = Set<Int32>()
        for window in windows where seen.insert(window.process.pid).inserted {
            guard clock.systemUptime < deadline else { result.status = .partial; break }
            var issues = [MetadataIssue]()
            let first = reader.read(window.process, deadline: deadline, issues: &issues)
            let states = reader.fullScreen
            reader.fullScreen.removeAll()
            let second = reader.read(window.process, deadline: deadline, issues: &issues)
            guard issues.isEmpty, first == second, clock.systemUptime <= deadline,
                  first.allSatisfy({ states[$0.elementToken] == reader.fullScreen[$0.elementToken] }),
                  incarnation(window.process.pid) == window.process else {
                result.status = .partial; continue
            }
            result.values[window.process.pid] = second
            result.fullScreen.merge(reader.fullScreen) { _, new in new }
        }
        return result
    }

    func activeNumbers() -> Set<UInt32> {
        observedActiveNumbers() ?? []
    }

    func observedActiveNumbers() -> Set<UInt32>? {
        // The allSpaces flag must stay absent. Only numbers are requested from AppKit.
        guard let active = Self.windowNumberSet(NSWindow.windowNumbers(options: .allApplications)) else { return nil }
        if let fixture = request.fixtureWindows { return active.intersection(fixture) }
        return active
    }

    nonisolated static func windowNumberSet(_ raw: [NSNumber]?) -> Set<UInt32>? {
        guard let raw, raw.count <= 16_384 else { return nil }
        let numbers = raw.compactMap { SpaceInventory.integer($0).flatMap { UInt32($0.stringValue) } }
        let active = Set(numbers)
        guard numbers.count == raw.count, active.count == raw.count, !active.contains(0) else { return nil }
        return active
    }

    func sample() throws -> DesktopSnapshot {
        let console = CGSessionCopyCurrentDictionary() as? [String: Any]
        #if NEARPANE_ISOLATED_GUI_LAB
        // This separately compiled test helper can only inspect its parent's one
        // marked window in a different user's GUI, or perform a scope-only read.
        var physicalConsole = stat()
        let scopedConsole = CommandLine.arguments.dropFirst().first == "--read-enrolled-console"
        guard stat("/dev/console", &physicalConsole) == 0,
              scopedConsole ? (physicalConsole.st_uid == getuid() && console?[kCGSessionOnConsoleKey as String] as? Bool == true) : physicalConsole.st_uid != getuid(),
              console?[kCGSessionUserIDKey as String] as? UInt32 == getuid(),
              console?[kCGSessionLoginDoneKey as String] as? Bool == true,
              console?["CGSSessionScreenIsLocked"] as? Bool != true,
              request.parentPID == getppid(), request.experimentalSpaces,
              let allowedIDs = request.fixtureWindows, allowedIDs.count <= 1,
              request.anchors.map(\.number) == allowedIDs, request.anchors.allSatisfy({ $0.witness == .ownedWindow })
        else { throw DesktopActionError.unsupported }
        #else
        guard console?["kCGSSessionOnConsoleKey"] as? Bool == true,
              console?["CGSSessionScreenIsLocked"] as? Bool != true else { throw DesktopActionError.unsupported }
        #endif
        let build = clock.operatingSystemVersionString
        let stageBefore = StageManagerPreference.read()
        let from = Date(), start = clock.systemUptime, before = try Topology(), list = try windowList()
        var status: SpaceReadStatus = .disabled
        if request.experimentalSpaces {
            switch NPReadOnlySpacesOpen() {
            case 1: status = .observed
            case 0: status = .unsupportedBuild
            default: status = .unavailable
            }
        }
        let activeBefore = activeNumbers()
        let ids = list.windows.map(\.windowID)
        let first = status == .observed ? SpaceBoundary.read(displays: before.displays, windowIDs: ids) : nil
        let ax = accessibility(list.windows, deadline: start + 1.25)
        let second = first?.inventory == nil ? nil : SpaceBoundary.read(displays: before.displays, windowIDs: ids)
        let activeAfter = activeNumbers()
        let again = try windowList(), topology = try Topology(), end = clock.systemUptime
        let stageAfter = StageManagerPreference.read()
        let stable = before == topology && list == again && stageBefore == stageAfter && end-start <= 3
        if status == .observed {
            if first?.inventory == nil || second?.inventory == nil { status = .unavailable }
            else if !stable || first != second { status = .unstable }
        }
        let boundary = status == .observed ? second : nil
        let scopes = boundary?.inventory?.scopes ?? []
        #if NEARPANE_ISOLATED_GUI_LAB
        if scopedConsole, request.fixtureWindows?.isEmpty == true, let inventory = boundary?.inventory {
            scopeTypes?(inventory.ordinaryRecordsByDisplay)
        }
        #endif
        var windows = [WindowObservation]()
        var candidates = request.anchors.filter { $0.witness == .ownedWindow }
        let elements = ax.values.sorted { $0.key < $1.key }.flatMap(\.value)
        let matches = WindowMatcher.matches(cg: list.windows, ax: elements)
        for (index, entry) in list.windows.enumerated() {
            if entry.process.pid == request.parentPID && request.fixtureWindows?.contains(entry.windowID) != true { continue }
            let slices = try before.geometry.slices(of: entry.frame)
            guard let slice = slices.max(by: { $0.fractionOfWindow < $1.fractionOfWindow }),
                  let display = before.displays.first(where: { $0.id == slice.displayID }) else { continue }
            let match = matches[index]
            let unique = match.confidence == .corroboratedMetadata || match.confidence == .geometryOnly
            let element = unique ? elements[match.axCandidateIndices[0]] : nil
            let standardNumber = element?.standardWindowNumber.flatMap { n in
                elements.filter { $0.process == entry.process && $0.standardWindowNumber == n }.count == 1 ? n : nil
            }
            let confidence: NearpaneCore.IdentityConfidence
            switch match.confidence {
            case .corroboratedMetadata where standardNumber != nil && standardNumber != entry.windowID: confidence = .ambiguous
            case .corroboratedMetadata: confidence = .corroboratedMetadata
            case .geometryOnly: confidence = .geometryOnly
            case .ambiguous: confidence = .ambiguous
            case .unknown: confidence = .unknown
            }
            let data = ObservedWindowMetadata(number: entry.windowID, pid: entry.process.pid,
                launchMicroseconds: entry.process.launchEpochMicroseconds, element: element?.elementToken,
                globalFrame: SurfaceRect(entry.frame), frontToBack: entry.frontToBackIndex,
                minimized: element?.minimized, fullScreen: element.flatMap { ax.fullScreen[$0.elementToken] },
                axFrame: element?.frame.map(SurfaceRect.init), isOnscreen: entry.isOnscreen,
                axStandardWindowNumber: standardNumber,
                onActiveDesktop: stable && activeBefore.contains(entry.windowID) && activeAfter.contains(entry.windowID))
            let local = SurfaceRect(x: entry.frame.x-display.frame.x, y: entry.frame.y-display.frame.y,
                                    width: entry.frame.width, height: entry.frame.height)
            let observed = WindowObservation(id: "\(request.revision)/\(entry.process.pid)/\(entry.windowID)", displayID: display.id,
                                 bounds: local, membership: boundary?.membership[entry.windowID] ?? .unknown,
                                 confidence: confidence, metadata: data)
            windows.append(observed)
            if observed.canWitnessCurrentSpace, entry.process.pid != request.parentPID,
               activeBefore.contains(entry.windowID), activeAfter.contains(entry.windowID) {
                candidates.append(.init(number: entry.windowID, displayID: display.id, globalFrame: data.globalFrame, witness: .appKitActiveList))
            }
        }
        let rows = boundary?.confirmedRows(displays: before.displays, separateSpaces: before.separateSpaces,
            complete: stable && !list.limited, candidates: candidates, windows: list.windows, parent: request.parentPID) ?? []
        return .observed(request, from: from, to: Date(), build: build, topology: before.fingerprint, consistent: stable && status != .unstable,
                         separateSpaces: before.separateSpaces, displays: before.displays, scopes: scopes, windows: windows,
                         evidence: .init(population: request.fixtureWindows == nil ? .workWindows : .markedFixture, accessibility: ax.status,
                                         spaces: status, rows: rows, windowLimitReached: list.limited, beganUptime: start, endedUptime: end,
                                         stageManagerEnabled: stageBefore == stageAfter ? stageAfter : nil))
    }
}

@main enum DesktopReader {
    @MainActor static func validate(_ request: DesktopReadRequest, overview: Bool) throws {
        guard request.version == 1, request.revision > 0, request.parentPID == getppid(),
              request.anchors.count <= 16, (request.fixtureWindows?.count ?? 0) <= 32 else { throw DesktopActionError.unsupported }
        if let targets = request.sidebarAuditWindows {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard overview, (1...2).contains(targets.count), Set(targets).count == targets.count,
                  proc_pidpath(getppid(), &path, UInt32(path.count)) > 0,
                  URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self))
                    .resolvingSymlinksInPath().path == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost"
            else { throw DesktopActionError.unsupported }
        }
    }

    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--self-check"] { print("Nearpane desktop reader 1"); return }
        do {
            #if NEARPANE_ISOLATED_GUI_LAB
            if arguments.count == 2, arguments[0] == "--enrolled-move-check", arguments[1].utf8.count <= 16384,
               let bytes = Data(base64Encoded: arguments[1]) {
                let request = try JSONDecoder().decode(EnrolledMoveRequest.self, from: bytes)
                let reply = try request.observe()
                FileHandle.standardOutput.write(try JSONEncoder().encode(reply))
                if !reply.matchesCheckpoint { exit(3) }
                return
            }
            if arguments.count == 4, ["--enrolled-route", "--enrolled-current-route"].contains(arguments[0]),
               let source = UInt32(arguments[2]), let target = UInt32(arguments[3]) {
                let result = try EnrolledRoute.sample(display: arguments[1], numbers: [source, target],
                                                      currentDisplayOnly: arguments[0] == "--enrolled-current-route")
                FileHandle.standardOutput.write(try JSONEncoder().encode(result))
                return
            }
            #else
            if arguments == ["--window-overview-service"] {
                NSApplication.shared.setActivationPolicy(.prohibited)
                let service = OverviewReaderService()
                service.start()
                withExtendedLifetime(service) { NSApplication.shared.run() }
                return
            }
            if arguments.count == 2, arguments[0] == "--admission", arguments[1].utf8.count < 16384,
               let bytes = Data(base64Encoded: arguments[1]) {
                let request = try JSONDecoder().decode(AdmissionReadRequest.self, from: bytes)
                FileHandle.standardOutput.write(try JSONEncoder().encode(AdmissionAXRead.observe(request)))
                return
            }
            #endif
            #if NEARPANE_ISOLATED_GUI_LAB
            let encodedCommands = ["--read-encoded", "--read-enrolled-console"]
            #else
            let encodedCommands = ["--read-encoded", "--window-overview"]
            #endif
            let bytes: Data
            if arguments == ["--read-once"] {
                bytes = FileHandle.standardInput.readData(ofLength: 8193)
            } else if arguments.count == 2, encodedCommands.contains(arguments[0]), arguments[1].utf8.count <= 10924,
                      let decoded = Data(base64Encoded: arguments[1]) {
                bytes = decoded
            } else { exit(2) }
            guard bytes.count <= 8192 else { exit(2) }
            let request = try JSONDecoder().decode(DesktopReadRequest.self, from: bytes)
            try validate(request, overview: arguments.first == "--window-overview")
            NSApplication.shared.setActivationPolicy(.prohibited)
            #if NEARPANE_ISOLATED_GUI_LAB
            var ordinary: [String: [String]]?
            let snapshot = try Reader(request: request, scopeTypes: { ordinary = $0 }).sample()
            if let ordinary, snapshot.isStructurallyValid {
                let reply = OrdinaryScopeSample(snapshot: snapshot, ordinaryRecordsByDisplay: ordinary)
                FileHandle.standardOutput.write(try JSONEncoder().encode(reply))
                return
            }
            #else
            let reader = Reader(request: request)
            let snapshot = try arguments.first == "--window-overview" ? reader.windowOverview() : reader.sample()
            #endif
            guard snapshot.isStructurallyValid else { exit(3) }
            FileHandle.standardOutput.write(try JSONEncoder().encode(snapshot))
        } catch { FileHandle.standardError.write(Data("Read-only desktop sample unavailable.\n".utf8)); exit(3) }
    }
}

#if NEARPANE_ISOLATED_GUI_LAB
private struct OrdinaryScopeSample: Encodable {
    let snapshot: DesktopSnapshot
    let ordinaryRecordsByDisplay: [String: [String]]
    private enum Keys: String, CodingKey { case ordinaryRecordsByDisplay }
    func encode(to encoder: Encoder) throws {
        try snapshot.encode(to: encoder)
        var fields = encoder.container(keyedBy: Keys.self)
        try fields.encode(ordinaryRecordsByDisplay, forKey: .ordinaryRecordsByDisplay)
    }
}
#endif
