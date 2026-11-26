import Foundation
import XCTest
@testable import TileKit

final class TileKitTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testSharedWidthUsesPointsAndReadableClamps() {
        XCTAssertEqual(TileGeometry.standaloneWidth(visibleWidth: 1280), 176)
        XCTAssertEqual(TileGeometry.standaloneWidth(visibleWidth: 1470), 184)
        XCTAssertEqual(TileGeometry.standaloneWidth(visibleWidth: 1664), 208)
        XCTAssertEqual(TileGeometry.standaloneWidth(visibleWidth: 1920), 224)
        XCTAssertEqual(TileGeometry.standaloneWidth(visibleWidth: .nan), 176)
    }
    func testDefaultOrderAndOverflowDoNotIntersectOrLeaveScreen() {
        let display = TileDisplay(id: "main", width: 1470, height: 700, isPrimary: true)
        let members = [TileMember(id: "lyrictile"), TileMember(id: "riftlet", reservedHeight: 212),
                       TileMember(id: "saytile", reservedHeight: 62), TileMember(id: "overflow", reservedHeight: 272)]
        let p = TileGeometry.placements(members: members, displays: [display])
        XCTAssertEqual(p["saytile"]?.rect.y, 16)
        XCTAssertEqual(p["riftlet"]?.rect.y, 88)
        XCTAssertEqual(p["lyrictile"]?.rect.y, 310)
        XCTAssertNil(p["overflow"])
        let values = Array(p.values)
        for a in values.indices { for b in values.indices where a != b { XCTAssertFalse(values[a].rect.intersects(values[b].rect)) } }
    }
    func testAReconnectedPreferredScreenDoesNotStealCurrentPlacement() {
        let member = TileMember(id: "lyrictile", preferredDisplayID: "external")
        let main = TileDisplay(id: "main", width: 1470, height: 800, isPrimary: true)
        let first = TileGeometry.placements(members: [member], displays: [main])
        let external = TileDisplay(id: "external", width: 1920, height: 1080)
        let later = TileGeometry.placements(members: [member], displays: [main, external], previous: first)
        XCTAssertEqual(later["lyrictile"]?.displayID, "main")
    }
    func testLegacyWindowIsAvoidedAndNewMemberAppendsToUserOrder() {
        let screen = TileDisplay(id: "main", width: 1470, height: 900)
        let oldWindow = TilePlacement(displayID: "main", rect: TileRect(x: 1260, y: 16, width: 194, height: 212))
        let members = [TileMember(id: "lyrictile", userOrder: 20), TileMember(id: "saytile", reservedHeight: 62)]
        let result = TileGeometry.placements(members: members, displays: [screen], obstacles: [oldWindow])
        XCTAssertEqual(result["lyrictile"]?.rect.y, 238)
        XCTAssertEqual(result["saytile"]?.rect.y, 520)
        XCTAssertFalse(result["lyrictile"]!.rect.intersects(oldWindow.rect))
    }
    func testInvalidModuleCannotAliasAnUnrelatedSessionLock() throws {
        let lease = TileSessionLease(moduleID: "../../other", directory: try temporary())
        XCTAssertThrowsError(try lease.acquire()) { XCTAssertEqual($0 as? TileCoordinationError, .invalidIdentifier) }
    }
    func testLifetimeLeaseCannotBeAcquiredBySecondInstance() throws {
        let directory = try temporary(), a = TileSessionLease(directory: directory), b = TileSessionLease(directory: directory)
        XCTAssertTrue(try a.acquire()); XCTAssertFalse(try b.acquire())
        a.release(); XCTAssertTrue(try b.acquire()); b.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session-lyrics.lock").path))
    }
    func testReorderWaitsForExplicitHideAndIndependentWindowAbsence() throws {
        let registry = TileRegistry(directory: try temporary())
        let screen = TileDisplay(id: "main", width: 1470, height: 900, isPrimary: true)
        let lyric = TileMember(id: "lyrictile", windowIDs: [101])
        let first = try registry.reconcile(lyric, displays: [screen], observation: .init(visibleWindowIDs: []))
        XCTAssertEqual(first.phase, .stable)
        let voice = TileMember(id: "saytile", reservedHeight: 62, windowIDs: [102])
        let moving = try registry.reconcile(voice, displays: [screen], observation: .init(visibleWindowIDs: [101]))
        XCTAssertEqual(moving.phase, .withdrawing); XCTAssertFalse(moving.mayShow("lyrictile")); XCTAssertFalse(moving.mayShow("saytile"))
        let premature = try registry.acknowledgeHidden(id: lyric.id, instanceID: lyric.instanceID, generation: moving.generation,
                                                     observation: .init(visibleWindowIDs: [101]))
        XCTAssertEqual(premature.phase, .withdrawing)
        let stable = try registry.acknowledgeHidden(id: lyric.id, instanceID: lyric.instanceID, generation: moving.generation,
                                                  observation: .init(visibleWindowIDs: []))
        XCTAssertEqual(stable.phase, .stable); XCTAssertEqual(stable.placements["lyrictile"]?.rect.y, 88)
    }
    func testLeaseAgeAloneNeverReclaimsVisibleMember() throws {
        let registry = TileRegistry(directory: try temporary()), screen = TileDisplay(id: "main", width: 1470, height: 900)
        let old = TileMember(id: "saytile", reservedHeight: 62, windowIDs: [99])
        _ = try registry.reconcile(old, displays: [screen], observation: .init(visibleWindowIDs: []), now: Date(timeIntervalSince1970: 0))
        let lyric = TileMember(id: "lyrictile")
        let plan = try registry.reconcile(lyric, displays: [screen], observation: .init(visibleWindowIDs: [99]), now: Date())
        XCTAssertNotNil(plan.placements["saytile"])
        XCTAssertNotNil(try registry.snapshot().members["saytile"])
    }
    func testCorruptRegistryIsNotSilentlyReplacedWithAnEmptyPlan() throws {
        let directory = try temporary(), registry = TileRegistry(directory: directory)
        try Data("invalid JSON".utf8).write(to: directory.appendingPathComponent("registry.json"))
        XCTAssertThrowsError(try registry.snapshot()) { XCTAssertEqual($0 as? TileCoordinationError, .corruptRegistry) }
    }
}
