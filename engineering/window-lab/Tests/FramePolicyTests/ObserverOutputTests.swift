import Foundation
import Testing
@testable import WindowLab

struct ObserverOutputTests {
    @Test func publishesOnlyCompletedNonemptyOutputAndPreservesExistingRevision() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: dir) }
        let target = dir.appendingPathComponent("snapshot-1.json")
        let sample = Data("{}".utf8)
        try publishObserverOutput(at: target) { handle in
            try handle.write(contentsOf: sample.prefix(1))
            #expect(!fm.fileExists(atPath: target.path))
            try handle.write(contentsOf: sample.suffix(1))
        }
        #expect(try Data(contentsOf: target) == sample)
        #expect(throws: POSIXError.self) {
            try publishObserverOutput(at: target) { try $0.write(contentsOf: Data("other".utf8)) }
        }
        #expect(try Data(contentsOf: target) == sample)
        let other = dir.appendingPathComponent("snapshot-2.json")
        #expect(throws: Refusal.self) {
            try publishObserverOutput(at: other) { handle in
                try handle.write(contentsOf: sample.prefix(1))
                throw Refusal("reader refused")
            }
        }
        #expect(throws: Refusal.self) { try publishObserverOutput(at: other) { _ in } }
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == [target.lastPathComponent])
    }
}
