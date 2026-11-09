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

    private struct List: Equatable {
        var windows: [CGWindowMetadata] = []
        var limited = false
    }

    private func visible() throws -> List {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { throw DesktopActionError.unsupported }
        var result = List(), seen = Set<UInt32>(), allowed = [Int32: Bool](), processes = [Int32: ProcessIdentity]()
        let fixture = request.fixtureWindows.map(Set.init), anchors = Set(request.anchors.map(\.number))
        for row in list {
            guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0,
                  let number = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value, number != 0,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0 else { continue }
            if let fixture {
                guard pid == request.parentPID, fixture.contains(number) || anchors.contains(number) else { continue }
            } else if pid == request.parentPID {
                guard anchors.contains(number) else { continue }
            } else {
                if allowed[pid] == nil {
                    let app = NSRunningApplication(processIdentifier: pid)
                    let id = app?.bundleIdentifier?.lowercased() ?? ""
                    allowed[pid] = app?.activationPolicy == .regular && !id.isEmpty && !id.hasPrefix("com.holdsnow.nearpane")
                        && !["com.apple.dock","com.apple.windowmanager","com.apple.loginwindow"].contains(id)
                }
                guard allowed[pid] == true else { continue }
            }
            guard seen.insert(number).inserted, let fields = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: fields) else { throw GeometryError.invalidGeometry }
            let frame = Rect(rect.minX, rect.minY, rect.width, rect.height)
            guard frame.isValid else { continue }
            guard result.windows.count < windowLimit else { result.limited = true; break }
            let process = processes[pid] ?? incarnation(pid); processes[pid] = process
            result.windows.append(CGWindowMetadata(process: process, windowID: number,
                title: (row[kCGWindowName as String] as? String).flatMap(titleToken), frame: frame,
                frontToBackIndex: result.windows.count))
        }
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

    func sample() throws -> DesktopSnapshot {
        let build = clock.operatingSystemVersionString
        let from = Date(), start = clock.systemUptime, before = try Topology(), list = try visible()
        var status: SpaceReadStatus = .disabled
        if request.experimentalSpaces {
            switch NPReadOnlySpacesOpen() {
            case 1: status = .observed
            case 0: status = .unsupportedBuild
            default: status = .unavailable
            }
        }
        let ids = list.windows.map(\.windowID)
        let first = status == .observed ? SpaceBoundary.read(displays: before.displays, windowIDs: ids) : nil
        let ax = accessibility(list.windows, deadline: start + 1.25)
        let second = first?.inventory == nil ? nil : SpaceBoundary.read(displays: before.displays, windowIDs: ids)
        let again = try visible(), topology = try Topology(), end = clock.systemUptime
        let stable = before == topology && list == again && end-start <= 3
        if status == .observed {
            if first?.inventory == nil || second?.inventory == nil { status = .unavailable }
            else if !stable || first != second { status = .unstable }
        }
        let boundary = status == .observed ? second : nil
        let scopes = boundary?.inventory?.scopes ?? []
        var windows = [WindowObservation]()
        let elements = ax.values.sorted { $0.key < $1.key }.flatMap(\.value)
        let matches = WindowMatcher.matches(cg: list.windows, ax: elements)
        for (index, entry) in list.windows.enumerated() {
            if entry.process.pid == request.parentPID && request.fixtureWindows?.contains(entry.windowID) != true { continue }
            let slices = try before.geometry.slices(of: entry.frame)
            guard let slice = slices.max(by: { $0.fractionOfWindow < $1.fractionOfWindow }),
                  let display = before.displays.first(where: { $0.id == slice.displayID }) else { continue }
            let match = matches[index]
            let element = match.axCandidateIndices.count == 1 ? elements[match.axCandidateIndices[0]] : nil
            let confidence: NearpaneCore.IdentityConfidence
            switch match.confidence {
            case .corroboratedMetadata: confidence = .corroboratedMetadata
            case .geometryOnly: confidence = .geometryOnly
            case .ambiguous: confidence = .ambiguous
            case .unknown: confidence = .unknown
            }
            let data = ObservedWindowMetadata(number: entry.windowID, pid: entry.process.pid,
                launchMicroseconds: entry.process.launchEpochMicroseconds, element: element?.elementToken,
                globalFrame: SurfaceRect(entry.frame), frontToBack: entry.frontToBackIndex,
                minimized: element?.minimized, fullScreen: element.flatMap { ax.fullScreen[$0.elementToken] })
            let local = SurfaceRect(x: entry.frame.x-display.frame.x, y: entry.frame.y-display.frame.y,
                                    width: entry.frame.width, height: entry.frame.height)
            windows.append(.init(id: "\(request.revision)/\(entry.process.pid)/\(entry.windowID)", displayID: display.id,
                                 bounds: local, membership: boundary?.membership[entry.windowID] ?? .unknown,
                                 confidence: confidence, metadata: data))
        }
        var rows: [ObservedSpaceRow] = []
        // A linked multi-display Space lacks a verified global grouping on this build.
        if let boundary, !list.limited, before.displays.count == 1 || before.separateSpaces {
            for display in before.displays {
                guard let scope = scopes.first(where: { $0.displayID == display.id }),
                      let current = scope.records.first(where: \.isCurrent),
                      let anchor = request.anchors.first(where: { anchor in
                          anchor.displayID == display.id && display.frame.geometry.intersection(anchor.globalFrame.geometry) == anchor.globalFrame.geometry &&
                          boundary.membership[anchor.number] == .known(recordIDs: [current.id]) &&
                          list.windows.contains { $0.windowID == anchor.number && $0.process.pid == request.parentPID &&
                              $0.process.hasLifecycleEvidence && $0.frame.componentError(from: anchor.globalFrame.geometry) <= 2 }
                      }) else { continue }
                rows.append(.init(displayID: display.id, scopeID: scope.id, recordID: current.id, anchor: anchor))
            }
        }
        return .observed(request, from: from, to: Date(), build: build, topology: before.fingerprint, consistent: stable && status != .unstable,
                         separateSpaces: before.separateSpaces, displays: before.displays, scopes: scopes, windows: windows,
                         evidence: .init(population: request.fixtureWindows == nil ? .workWindows : .markedFixture, accessibility: ax.status,
                                         spaces: status, rows: rows, windowLimitReached: list.limited, beganUptime: start, endedUptime: end))
    }
}

@main enum DesktopReader {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--self-check"] { print("Nearpane desktop reader 1"); return }
        do {
            let bytes: Data
            if arguments == ["--read-once"] {
                bytes = FileHandle.standardInput.readData(ofLength: 8193)
            } else if arguments.count == 2, arguments[0] == "--read-encoded", arguments[1].utf8.count <= 10924,
                      let decoded = Data(base64Encoded: arguments[1]) {
                bytes = decoded
            } else { exit(2) }
            guard bytes.count <= 8192 else { exit(2) }
            let request = try JSONDecoder().decode(DesktopReadRequest.self, from: bytes)
            guard request.version == 1, request.revision > 0, request.parentPID == getppid(),
                  request.anchors.count <= 16, (request.fixtureWindows?.count ?? 0) <= 32 else { exit(2) }
            NSApplication.shared.setActivationPolicy(.prohibited)
            let snapshot = try Reader(request: request).sample()
            guard snapshot.isStructurallyValid else { exit(3) }
            FileHandle.standardOutput.write(try JSONEncoder().encode(snapshot))
        } catch { FileHandle.standardError.write(Data("Read-only desktop sample unavailable.\n".utf8)); exit(3) }
    }
}
