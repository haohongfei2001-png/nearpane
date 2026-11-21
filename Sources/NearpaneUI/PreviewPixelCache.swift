import CoreGraphics
import Foundation
import Observation

/// All full-colour window stills in one Host share these limits. The optional picker
/// owns one slot so it cannot evict the visible card that the user is inspecting.
enum PreviewPixelBudget {
    static let pickerBytes = 4 * 1024 * 1024
    static let galleryBytes = 256 * 1024 * 1024 - pickerBytes
    static let galleryCount = 127

    static func charge(_ image: CGImage) -> Int? {
        // Charge both the actual stride (including padding) and a second decoded
        // surface. Include at least 32 bits/pixel even for packed source formats.
        let (rgba, wide) = image.width.multipliedReportingOverflow(by: 4)
        let (raster, tall) = max(rgba, image.bytesPerRow).multipliedReportingOverflow(by: image.height)
        let (both, overflow) = raster.multipliedReportingOverflow(by: 2)
        return wide || tall || overflow || both <= 0 ? nil : both
    }
}

@MainActor @Observable final class PreviewPixelCache<Key: Hashable, Value> {
    @Observable fileprivate final class Entry {
        var value: Value
        @ObservationIgnored var cost: Int
        init(value: Value, cost: Int) { self.value = value; self.cost = cost }
    }
    @ObservationIgnored var onRemoval: ((Key) -> Void)?
    private var entries = [Key: Entry]()
    // Reads update LRU order without invalidating a SwiftUI body that just read an image.
    @ObservationIgnored private var lastUse = [Key: UInt64]()
    @ObservationIgnored private var tick: UInt64 = 0
    private(set) var bytes = 0
    var count: Int { entries.count }
    private let maxCount, maxBytes: Int

    init(maxCount: Int = PreviewPixelBudget.galleryCount, maxBytes: Int = PreviewPixelBudget.galleryBytes) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    func contains(_ key: Key) -> Bool { entries[key] != nil }
    func peek(_ key: Key) -> Value? { entries[key]?.value }
    func touch(_ key: Key) {
        guard entries[key] != nil else { return }
        tick &+= 1
        lastUse[key] = tick
    }

    func store(_ value: Value, for key: Key, cost: Int) {
        guard cost > 0, cost <= maxBytes, maxCount > 0 else { remove(key); return }
        let existing = entries[key], prior = existing?.cost ?? 0
        while (existing == nil && entries.count >= maxCount) || bytes - prior > maxBytes - cost {
            guard let oldest = lastUse.filter({ $0.key != key }).min(by: { $0.value < $1.value })?.key else { return }
            remove(oldest)
        }
        if let existing {
            existing.value = value
            existing.cost = cost
        } else { entries[key] = Entry(value: value, cost: cost) }
        if cost != prior { bytes += cost - prior }
        touch(key)
    }

    func remove(_ key: Key) {
        guard let entry = entries[key] else { return }
        entries.removeValue(forKey: key)
        onRemoval?(key)
        bytes -= entry.cost
        lastUse.removeValue(forKey: key)
    }

    func remove(where predicate: (Key, Value) -> Bool) {
        for (key, entry) in entries where predicate(key, entry.value) { remove(key) }
    }
    func removeAll() {
        if let onRemoval { for key in entries.keys { onRemoval(key) } }
        entries.removeAll()
        lastUse.removeAll()
        bytes = 0
    }
}
