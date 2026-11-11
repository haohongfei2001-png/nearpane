import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@Suite @MainActor struct AdmissionDisplayPreviewTests {
    let main = ScreenGeometry(id: "main", frame: .init(width: 1000, height: 800),
                              visibleFrame: .init(width: 1000, height: 800))
    let side = ScreenGeometry(id: "side", frame: .init(x: -800, y: -480, width: 800, height: 1280),
                              visibleFrame: .init(x: -800, y: -480, width: 800, height: 1280),
                              rotationDegrees: 90, backingScale: 2)

    private func read(_ number: UInt32, first: String, second: String) -> AdmissionPair {
        let token = UUID(), time = ProcessInfo.processInfo.systemUptime
        func sample(_ display: String, at: Double) -> AdmissionSample {
            var s = AdmissionSample(pid: 123, launch: 42, number: number, bundle: "sample", uptime: at)
            s.element = token; s.axNumber = number; s.display = display
            s.cgFrame = .init(x: display == main.id ? 20 : -700, y: 30, width: 150, height: 160)
            s.axFrame = s.cgFrame; s.minimum = .init(width: 100, height: 100)
            s.role = .ordinary; s.fullscreen = false; s.minimized = false; s.layer = 0; s.onScreen = true
            s.positionSettable = true; s.sizeSettable = true; s.editGeneration = "1"
            s.selectionContinuity = true; s.recoveryVerified = true; s.permission = true
            return s
        }
        return .init(first: sample(first, at: time - 0.15), second: sample(second, at: time))
    }

    @Test func physicalDisplaysUseTheirOwnMembersCoordinatesAndSettings() throws {
        var config = HostConfiguration()
        config.preferredDisplayID = main.id
        config.displays[main.id, default: .init()].measures[.reservedWidth] = Measure(200)
        config.displays[main.id, default: .init()].edge = .left
        config.displays[side.id, default: .init()].placement = .floating
        let groups = AdmissionDisplayPreview.groups([read(11, first: side.id, second: side.id),
                                                     read(12, first: main.id, second: main.id)],
                                                    screens: [main,side], config: config, scenario: .current,
                                                    ratio: 0.5, swap: false, custom: false, recovery: true, exclusive: true)
        #expect(groups.map(\.id) == [main.id,side.id])
        let expected = [SurfaceRect(x: 200, width: 800, height: 800), SurfaceRect(x: -800, width: 800, height: 1280)]
        for (group, rect) in zip(groups, expected) {
            let preview = WindowAdmissionPreview.evaluate(group.pairs, context: group.context, uptime: ProcessInfo.processInfo.systemUptime)
            #expect(preview.workRect == rect && Array(preview.proposed.values) == [rect])
            #expect(preview.proposed.keys.first?.number == group.pairs.first?.second.number)
        }
    }

    @Test func transitionAndConflictingWindowNumberRemainUnlocated() {
        let groups = AdmissionDisplayPreview.groups([read(4, first: side.id, second: main.id),
                                                     read(8, first: side.id, second: side.id),
                                                     read(8, first: main.id, second: main.id)],
                                                    screens: [main,side], config: .init(), scenario: .current,
                                                    ratio: 0.5, swap: false, custom: false, recovery: true, exclusive: true)
        #expect(groups.count == 1 && groups[0].id.isEmpty)
        let preview = WindowAdmissionPreview.evaluate(groups[0].pairs, context: groups[0].context,
                                                      uptime: ProcessInfo.processInfo.systemUptime)
        #expect(preview.preparation == nil && preview.proposed.isEmpty)
    }
}
