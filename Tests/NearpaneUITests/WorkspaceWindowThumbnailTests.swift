import AppKit
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct WorkspaceWindowThumbnailTests {
    private func observation(pid: Int32 = getpid(), number: UInt32 = 101, launch: UInt64? = 123,
                             minimized: Bool = false, onScreen: Bool = true) -> WindowObservation {
        let frame = SurfaceRect(width: 640, height: 480)
        return .init(id: "sample", displayID: "display", bounds: frame, membership: .unknown,
            confidence: .geometryOnly, metadata: .init(number: number, pid: pid,
                launchMicroseconds: launch, element: nil, globalFrame: frame, frontToBack: 0,
                minimized: minimized, fullScreen: false, isOnscreen: onScreen))
    }

    @Test func fixtureCanSelectOnlyItsOwnProcess() throws {
        let owned = try #require(WorkspaceWindowThumbnails.WindowKey(observation()))
        let other = try #require(WorkspaceWindowThumbnails.WindowKey(observation(pid: getpid() + 1)))
        #expect(owned.permits(.markedFixture))
        #expect(!other.permits(.markedFixture))
        #expect(!owned.permits(.workWindows))
        #expect(other.permits(.workWindows))
    }

    @Test func missingAndRetiredWindowIdentitiesCannotSupplyAnImage() {
        #expect(WorkspaceWindowThumbnails.WindowKey(observation(number: 0)) == nil)
        #expect(WorkspaceWindowThumbnails.WindowKey(observation(launch: nil)) == nil)
        #expect(WorkspaceWindowThumbnails.WindowKey(observation(minimized: true)) == nil)
        #expect(WorkspaceWindowThumbnails.WindowKey(observation(onScreen: false)) == nil)
        let old = WorkspaceWindowThumbnails.WindowKey(observation(launch: 10))
        let replacement = WorkspaceWindowThumbnails.WindowKey(observation(launch: 11))
        #expect(old != replacement)
        #expect(old?.stillMatches(CGRect(x: 0, y: 0, width: 640, height: 480)) == false)
    }
}
