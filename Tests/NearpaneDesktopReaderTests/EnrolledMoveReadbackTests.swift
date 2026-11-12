import Foundation
import Testing
import NearpaneCore
@testable import NearpaneDesktopReader

struct EnrolledMoveReadbackTests {
    let original = SurfaceRect(x: -720, y: 10, width: 180, height: 160)
    let target = SurfaceRect(x: -700, y: 20, width: 240, height: 160)
    let run = UUID(), operation = UUID()
    func sample(_ checkpoint: EnrolledMoveCheckpoint, change: String = "") -> EnrolledMoveReadback {
        let p = EnrolledMovePlan(run: change == "other run" ? UUID() : run, operation: change == "other operation" ? UUID() : operation,
            pid: 99, launch: change == "new owner" ? 20 : 10, display: "secondary", source: "A", target: "B",
            sourceAnchor: 1, targetAnchor: 2, member: change == "alias" ? 1 : 3, destinationFrame: target)
        let moved = checkpoint == .atDestination
        var frames: [UInt32: SurfaceRect] = [1: original, 2: original, 3: moved ? target : original]
        var membership: [UInt32: String] = [1: "A", 2: "B", 3: moved ? "B" : "A"]
        var visible: Set<UInt32> = [moved ? 2 : 1, 3]
        switch change {
        case "member stayed": membership[3] = moved ? "A" : "B"
        case "source sibling followed": membership[1] = "B"
        case "destination sibling followed": membership[2] = "A"
        case "missing sibling": membership[2] = nil
        case "sibling resized": frames[1]?.width += 1
        case "incorrect layout": frames[3]?.x += 1
        case "not visible": visible.remove(3)
        case "sibling visible in wrong space": visible.insert(moved ? 1 : 2)
        default: break
        }
        let route = NativeRouteEvidence(topology: change == "rotated" ? "other" : "screens",
            currents: ["secondary": moved ? "B" : "A", "primary": change == "main switched" ? "N" : "M"],
            orders: ["secondary": change == "reordered" ? ["B", "A"] : ["A", "B"], "primary": ["M", "N"]], membership: membership)
        return .init(plan: p, build: "fixture", uptime: checkpoint == .before || change == "stale" ? 1 : 2,
                     route: route, frames: frames, visible: visible)
    }

    @Test(arguments: [EnrolledMoveCheckpoint.atDestination, .backAtSource])
    func independentlyChecksDestinationAndOriginalLayout(_ checkpoint: EnrolledMoveCheckpoint) {
        let before = sample(.before)
        #expect(before.verifies(.before, original: nil))
        #expect(sample(checkpoint).verifies(checkpoint, original: before))
        #expect(!sample(checkpoint).verifies(checkpoint, original: nil))
        #expect(!before.verifies(.backAtSource, original: before))
    }

    @Test(arguments: ["member stayed", "source sibling followed", "destination sibling followed", "missing sibling",
                      "sibling resized", "incorrect layout", "not visible", "sibling visible in wrong space",
                      "rotated", "main switched", "reordered", "stale", "new owner", "other run", "other operation", "alias"])
    func partialOrUnrelatedEvidenceIsRefused(_ change: String) {
        let before = sample(.before)
        for phase: EnrolledMoveCheckpoint in [.atDestination, .backAtSource] {
            #expect(!sample(phase, change: change).verifies(phase, original: before))
        }
    }
}
