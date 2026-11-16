import Foundation
import NearpaneCore
@testable import NearpaneUI
import Testing

@MainActor struct WindowContentPreviewTests {
    private let now = Date()
    private let frame = SurfaceRect(x: 90, y: 60, width: 250, height: 300)

    private func sample(session: UUID, birth: UInt64 = 200, number: UInt32 = 21,
                        axNumber: UInt32 = 21, x: Double = 90, cgOverride: SurfaceRect? = nil,
                        access: AXReadStatus = .available) -> DesktopSnapshot {
        let ax = SurfaceRect(x: x, y: frame.y, width: frame.width, height: frame.height)
        let cg = cgOverride ?? ax
        let window = WindowObservation(id: "observation", displayID: "fixture", bounds: cg, membership: .unknown,
            confidence: .corroboratedMetadata, metadata: .init(number: number, pid: 12, launchMicroseconds: birth,
                element: UUID(), globalFrame: cg, frontToBack: 0, minimized: false, fullScreen: false,
                axFrame: ax, isOnscreen: true, axStandardWindowNumber: axNumber))
        let display = SurfaceRect(width: 800, height: 640)
        return .observed(.init(session: session, revision: 1, parentPID: 10, fixtureWindows: nil, anchors: [], experimentalSpaces: false),
            from: now, to: now, build: "fixture", topology: "T", consistent: true, separateSpaces: true,
            displays: [.init(id: "fixture", frame: display, rotationDegrees: 0, backingScale: 2, usable: display)],
            scopes: [], windows: [window], evidence: .init(population: .workWindows, accessibility: access,
                spaces: .disabled, rows: [], windowLimitReached: false, beganUptime: 2, endedUptime: 3))
    }

    @Test func pixelBindingRequiresSameSessionProcessWindowGeometryAndFreshReadback() throws {
        let session = UUID(), good = sample(session: session)
        let bound = try #require(PreviewWindowBinding(good, window: good.windows[0]))
        #expect(bound.window(in: good, now: now, uptime: 3)?.id == good.windows[0].id)
        for other in [sample(session: UUID()), sample(session: session, birth: 201),
                      sample(session: session, number: 22, axNumber: 22), sample(session: session, x: 93),
                      sample(session: session, axNumber: 0), sample(session: session, access: .denied)] {
            #expect(bound.window(in: other, now: now, uptime: 3) == nil)
        }
        #expect(bound.window(in: good, now: now.addingTimeInterval(15), uptime: 18) == nil)
    }

    @Test func movingToAnotherDesktopRevokesAStillEvenWhenTheFrameIsIdentical() throws {
        let s = sample(session: UUID())
        let original = try #require(PreviewWindowBinding(s, window: s.windows[0]))
        var other = s
        other.scopes = [.init(id: "scope", displayID: original.display, records: [.init(id: "A", isCurrent: true)])]
        let w = s.windows[0]
        let moved = WindowObservation(id: w.id, displayID: w.displayID, bounds: w.bounds, membership: .known(recordIDs: ["A"]),
                                      confidence: w.confidence, metadata: w.metadata)
        #expect(PreviewWindowBinding(other, window: w) != original)
        #expect(PreviewWindowBinding(s, window: moved) != original)
    }

    @Test func withdrawnPanelInvalidatesPickerAndInflightCaptureEvenIfItReopens() throws {
        let preview = WindowContentPreview()
        #expect(preview.beginSelection() == nil)
        preview.setVisible(true, on: "one")
        let original = try #require(preview.beginSelection())
        preview.setVisible(false, on: "one")
        preview.setVisible(true, on: "one")
        #expect(preview.operation != original)
        let replacement = try #require(preview.beginSelection())
        preview.setVisible(false, on: "unrelated")
        #expect(preview.operation == replacement)
        preview.clear()
        #expect(!preview.active && preview.image == nil)
    }

    @Test func previewHelperGrantsOnlyObservationAndRequiresTwoMatchingReads() throws {
        for command: OrdinaryWindowRequest.Action in [.write, .acknowledgeBoundary, .watchCreated, .takeCreated, .endCreated, .refresh] {
            #expect(!command.allowedForStillPreview)
        }
        let snapshot = sample(session: UUID())
        let bound = try #require(PreviewWindowBinding(snapshot, window: snapshot.windows[0]))
        var a = AdmissionSample(pid: bound.pid, launch: bound.birth, number: bound.number, bundle: "test", uptime: 1)
        a.element = UUID(); a.axNumber = bound.number; a.liveObservation = UUID()
        a.cgFrame = bound.bounds; a.axFrame = bound.bounds; a.display = bound.display
        a.permission = true; a.selectionContinuity = true; a.onScreen = true; a.layer = 0
        a.role = .ordinary; a.minimized = false; a.fullscreen = false
        let id = try #require(a.id)
        #expect(bound.confirms(.init(first: a, second: a), id: id))
        var changed = a
        changed.liveObservation = UUID()
        #expect(!bound.confirms(.init(first: a, second: changed), id: id))
        changed = a; changed.element = UUID()
        #expect(!bound.confirms(.init(first: a, second: changed), id: id))
        changed = a; changed.cgFrame?.width = 49
        #expect(!bound.confirms(.init(first: a, second: changed), id: id))
    }

    @Test func presentationThumbnailAndClippedWindowCannotSupplyContent() {
        let stage = sample(session: UUID(), cgOverride: .init(x: 2, y: 150, width: 49, height: 76))
        let clipped = sample(session: UUID(), x: -40)
        for snapshot in [stage, clipped] {
            #expect(PreviewWindowBinding(snapshot, window: snapshot.windows[0]) == nil)
        }
        let preview = WindowContentPreview()
        #expect(!preview.active && preview.image == nil)
        preview.clear()
        #expect(preview.binding == nil && preview.revision == nil)
    }
}
