import Testing
import NearpaneCore
@testable import NearpaneUI

@MainActor struct StageHostMiniatureGeometryTests {
    @Test(arguments: ["right", "leftAndTop", "allEdges", "inside"])
    func aVisibleMemberBoundsItsButtonWithoutResizingItsFullPicture(edge: String) throws {
        let canvas: SurfaceRect, original: SurfaceRect, visible: SurfaceRect, picture: SurfaceRect
        switch edge {
        case "right":
            // The failing AX receipt's 67-point button crossed the 208-point
            // content width. Its 28-point visible part must retain a 67-point image.
            canvas = .init(x: 800, y: 31, width: 208, height: 679)
            original = .init(x: 980, y: 141, width: 67, height: 54)
            visible = .init(x: 980, y: 141, width: 28, height: 54)
            picture = .init(width: 67, height: 54)
        case "leftAndTop":
            canvas = .init(x: 100, y: 200, width: 80, height: 60)
            original = .init(x: 90, y: 190, width: 40, height: 50)
            visible = .init(x: 100, y: 200, width: 30, height: 40)
            picture = .init(x: -10, y: -10, width: 40, height: 50)
        case "allEdges":
            canvas = .init(x: 100, y: 200, width: 80, height: 60)
            original = .init(x: 90, y: 190, width: 100, height: 100)
            visible = canvas
            picture = .init(x: -10, y: -10, width: 100, height: 100)
        default:
            canvas = .init(x: 100, y: 200, width: 80, height: 60)
            original = .init(x: 120, y: 220, width: 40, height: 20)
            visible = original
            picture = .init(width: 40, height: 20)
        }
        let frame = try #require(StageGroupMiniatureFrame(original: original, canvas: canvas))
        #expect(frame.original == original)
        #expect(frame.visible == visible)
        #expect(frame.pictureInVisibleFrame == picture)
    }

    @Test(arguments: ["outside", "touchingRight", "touchingBottom"])
    func aMemberWithoutVisibleAreaKeepsTheUnplacedMenuPath(position: String) {
        let canvas = SurfaceRect(x: 100, y: 200, width: 80, height: 60)
        let original: SurfaceRect
        switch position {
        case "touchingRight": original = .init(x: 180, y: 210, width: 20, height: 20)
        case "touchingBottom": original = .init(x: 110, y: 260, width: 20, height: 20)
        default: original = .init(x: 190, y: 210, width: 20, height: 20)
        }
        #expect(StageGroupMiniatureFrame(original: original, canvas: canvas) == nil)
    }
}
