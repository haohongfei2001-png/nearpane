import Darwin
import Foundation
import NearpaneCore

/// Evidence for a single retained window of the independently signed acceptance witness.
public struct EnrolledFullscreenObservation: Decodable, Equatable {
    public let run, token: UUID
    public let display, source, fullscreenCurrent, build, boot: String
    public let pid: Int32, launch: UInt64, number: UInt32, revision: UInt64
    public let expiresUptime: Double
    public let witnessSHA256, readerSHA256: String

    /// The controller enrolls a physical path. Foundation may present that same
    /// macOS path without its /private prefix. Other links are never enrollment.
    package static func matchesExecutablePath(enrolled: String, reported: String) -> Bool {
        func physicalPath(_ path: String) -> String? {
            guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(validatingCString: resolved)
        }
        guard physicalPath(enrolled) == enrolled else { return false }
        if reported == enrolled { return true }
        return enrolled == "/private" + reported && physicalPath(reported) == enrolled
    }

    public func sample(_ snapshot: DesktopSnapshot, sourceCurrents: [String: String], returned: Bool,
                       date: Date, uptime: Double, validUntil: Double) -> FullscreenDisplaySample? {
        let expectedRecord = returned ? source : fullscreenCurrent
        guard uptime.isFinite, validUntil.isFinite, uptime < validUntil,
              source != fullscreenCurrent, !source.isEmpty, !fullscreenCurrent.isEmpty,
              snapshot.sessionID == run, snapshot.revision >= revision,
              snapshot.sourceBuild == build, snapshot.separateSpaces == true,
              snapshot.displays.count == 2, snapshot.scopes.count == 2,
              sourceCurrents.count == 2, sourceCurrents[display] == source,
              Set(snapshot.scopes.map(\.displayID)) == Set(sourceCurrents.keys),
              snapshot.scopes.allSatisfy({ scope in
                  scope.records.filter(\.isCurrent).map(\.id) ==
                    [scope.displayID == display ? expectedRecord : sourceCurrents[scope.displayID]!]
              }),
              let native = snapshot.native, native.population == .markedFixture, native.spaces == .observed,
              uptime >= native.endedUptime, uptime - native.beganUptime < 4,
              snapshot.windows.count == 1, let w = snapshot.windows.first, w.displayID == display,
              w.metadata?.pid == pid, w.metadata?.launchMicroseconds == launch, w.metadata?.number == number,
              w.metadata?.axStandardWindowNumber == number, w.membership == .known(recordIDs: [expectedRecord]) else { return nil }
        // The normal production classifier verifies the AX fullscreen flag, standard AX/CG identity,
        // stable presentation, usable-frame coverage and frontmost position in this scoped population.
        let observation = snapshot.fullscreenObservation(for: display, now: date, uptime: uptime)
        switch (returned, observation) {
        case (false, .native(let owner)):
            guard owner.pid == pid, owner.launch == launch, owner.number == number else { return nil }
        case (true, .ordinary(let workspace)):
            guard let workspace, workspace == snapshot.workspaceID(display: display, record: source),
                  native.rows.contains(where: { $0.displayID == display && $0.recordID == source &&
                      $0.anchor.witness == .ownedWindow && $0.anchor.number == number }) else { return nil }
        default: return nil
        }
        return .init(session: run, revision: snapshot.revision, validUntil: min(validUntil, native.beganUptime + 4),
                     observation: observation, beganUptime: native.beganUptime)
    }
}
