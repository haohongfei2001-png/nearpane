import Foundation

// Entirely invented data. Never initializes AppKit, SkyLight or a desktop observation provider.
public enum SyntheticFixture {
    public static func state() -> ObservationState {
        let display = Display(id: 4_294_900_001, uuid: "SYNTHETIC-PRIVATE-DISPLAY-UUID", name: "SYNTHETIC-PRIVATE-NAME",
                              bounds: Rect(x: 0, y: 0, width: 1920, height: 1080), isMain: true)
        let scope = ManagedScope(identifier: display.uuid, spaces: [SpaceRecord(id: 8_001, rawType: 0), SpaceRecord(id: 8_002, rawType: 0)], currentSpaceID: 8_001)
        let window = WindowObservation(metadata: WindowMetadata(id: 4_294_900_002, pid: 12345, layer: 0,
            bounds: Rect(x: 10, y: 20, width: 600, height: 400), onscreen: true), membership: Membership(status: .known, spaceIDs: [8_001]))
        return ObservationState(osVersion: "SYNTHETIC", osBuild: "SYNTHETIC",
            boundary: Boundary(separateSpaces: false, topology: Topology(displays: [display]), inventory: Inventory(scopes: [scope])), windows: [window])
    }
    public static func sample(_ revision: Int, state: ObservationState? = nil) throws -> Sample {
        let state = state ?? self.state()
        let start = UInt64(revision) * 1_000_000_000
        return Sample(revision: revision, startedAt: timestamp(Date(timeIntervalSince1970: Double(revision))),
                      endedAt: timestamp(Date(timeIntervalSince1970: Double(revision) + 0.01)),
                      startedUptimeNS: start, endedUptimeNS: start + 10_000_000, state: state,
                      afterBoundary: state.boundary, afterWindowFingerprint: try fingerprint(state.windows.map(\.metadata)))
    }
}
