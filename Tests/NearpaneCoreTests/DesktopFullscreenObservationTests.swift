import Foundation
import NearpaneCore
import Testing

struct DesktopFullscreenObservationTests {
    let fixture = NativeDesktopPreviewTests()

    func window(full: Bool?, number: UInt32 = 7, axNumber: UInt32? = 7, z: Int = 0,
                frame: SurfaceRect? = nil, axFrame: SurfaceRect? = nil,
                confidence: IdentityConfidence = .geometryOnly) -> WindowObservation {
        let display = fixture.portrait
        let bounds = frame ?? display.frame
        let metadata = ObservedWindowMetadata(number: number, pid: 120, launchMicroseconds: 995,
            element: UUID(), globalFrame: bounds, frontToBack: z, minimized: false, fullScreen: full,
            axFrame: axFrame ?? bounds, isOnscreen: true, axStandardWindowNumber: axNumber)
        return .init(id: "sample-\(number)", displayID: display.id,
            bounds: .init(x: bounds.x - display.frame.x, y: bounds.y - display.frame.y, width: bounds.width, height: bounds.height),
            membership: .unknown, confidence: confidence, metadata: metadata)
    }

    func observe(_ snapshot: DesktopSnapshot, display: String = "portrait") -> DesktopFullscreenObservation {
        snapshot.fullscreenObservation(for: display, now: fixture.date, uptime: 42)
    }

    @Test func independentAXFlagDistinguishesFillFromFullscreenEvenWithoutTitlesOrSpaceInventory() throws {
        let plain = fixture.sample([window(full: false)])
        #expect(observe(plain) == .ordinary(workspace: nil))
        let full = window(full: true)
        var snapshot = fixture.sample([full])
        snapshot.scopes = []
        snapshot.native?.spaces = .disabled
        let token = try #require(full.metadata?.element)
        #expect(observe(snapshot) == .native(window: .init(pid: 120, launch: 995, number: 7, element: token)))
        #expect(ManagedWindowID(full) == nil) // the presentation observation did not admit a WorkRect write
        #expect(observe(snapshot, display: fixture.landscape.id) == .unknown)
        let reported = fixture.sample([window(full: false)], rows: [fixture.proof])
        #expect(observe(reported) == .ordinary(workspace: reported.workspaceID(display: "portrait", record: "9")))
    }

    @Test func missingAttributesRebuiltIdentityThumbnailAndIncompleteDisplayCannotOpenTools() {
        let thumbnail = SurfaceRect(x: -64, y: 602, width: 49, height: 76)
        let cases = [window(full: nil), window(full: true, axNumber: nil), window(full: true, axNumber: 55),
                     window(full: true, confidence: .ambiguous),
                     window(full: true, frame: thumbnail, axFrame: .init(x: -681, y: 64, width: 562, height: 422)),
                     window(full: true, frame: .init(x: -200, y: 0, width: 400, height: 640))]
        for candidate in cases { #expect(observe(fixture.sample([candidate])) == .unknown) }
        let foremost = window(full: true)
        let other = window(full: true, number: 9, axNumber: 9, z: 2)
        #expect(observe(fixture.sample([foremost, other])) == .unknown)
        #expect(observe(fixture.sample([window(full: false), other])) == .unknown)
        #expect(observe(fixture.sample([])) == .unknown)
    }

    @Test func matchingSmallFramesAndAnAXFullscreenFlagCannotExposeToolsOnTheDesktop() throws {
        let thumbnail = SurfaceRect(x: -64, y: 602, width: 49, height: 76)
        for stageManager in [true, false] {
            let small = fixture.sample([window(full: true, frame: thumbnail)], stageManager: stageManager)
            #expect(observe(small) == .unknown)
        }
        let usable = SurfaceRect(x: -800, y: 20, width: 800, height: 1260)
        let full = window(full: true, frame: usable)
        guard case .native = observe(fixture.sample([full], stageManager: true)) else {
            Issue.record("A corroborated fullscreen surface covering the usable display should be admitted")
            return
        }
    }

    @Test func invalidatedPermissionAndLateOrTransientReadCannotAuthorizeAnOverlay() {
        let full = window(full: true)
        var snapshot = fixture.sample([full])
        snapshot.freshness = .transient
        #expect(observe(snapshot) == .unknown)
        snapshot.freshness = .fresh
        #expect(snapshot.fullscreenObservation(for: "portrait", now: fixture.date, uptime: 54) == .unknown)
        for status in [AXReadStatus.partial, .denied] {
            snapshot.native = .init(population: .workWindows, accessibility: status, spaces: .observed,
                rows: [], windowLimitReached: false, beganUptime: 40, endedUptime: 41)
            #expect(observe(snapshot) == .unknown)
        }
        snapshot.native = .init(population: .workWindows, accessibility: .available, spaces: .observed,
            rows: [], windowLimitReached: true, beganUptime: 40, endedUptime: 41)
        #expect(observe(snapshot) == .unknown)
    }
}
