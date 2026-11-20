import CryptoKit
import Darwin
import Foundation
import ImageIO
import RiftletCore

struct ScreenshotArchiveEntry: Identifiable {
    let record: AssetRecord
    let attachment: String?
    var id: UUID { record.id }
    var date: Date { record.image.capturedAt ?? record.image.firstSeenAt }

    var visibility: String {
        switch record.visibility {
        case .visible: "在托盘中"
        case .removed: "已移出托盘"
        case .archived: "已归档"
        case .swallowed: "已离开托盘"
        }
    }

    init(_ row: QueueHistoryRecord, policy: ReceiptPolicy, mode: StoreMode) {
        record = row.record
        switch row.attachmentState {
        case .available: attachment = nil
        case .preparing: attachment = "正在准备附加"
        case .needsReview, .checkDraft: attachment = "结果待核对"
        case .handedOff: attachment = "已开始上传，待确认"
        case .confirmedFailure: attachment = "附加失败"
        case .notAttached: attachment = "未附加"
        case .attached:
            if let op = row.operation, let receipt = row.receipt,
               record.status == .used, record.activeOperationID == op.id,
               op.phase == .succeeded, receipt.operationID == op.id, receipt.assetID == record.id,
               op.assetID == record.id, receipt.attempt == op.attempt, receipt.target == op.target,
               receipt.assetSHA256 == record.image.sha256,
               policy.allowsConsumption(receipt: receipt, asset: record.image, mode: mode) {
                attachment = "已附加到草稿"
            } else {
                attachment = "结果待核对"
            }
        }
    }
}

struct ScreenshotArchivePage {
    static let size = 24
    let entries: [ScreenshotArchiveEntry]
    let hasOlder: Bool

    init(_ batch: [QueueHistoryRecord], policy: ReceiptPolicy, mode: StoreMode) {
        entries = batch.prefix(Self.size).map { ScreenshotArchiveEntry($0, policy: policy, mode: mode) }
        hasOlder = batch.count > Self.size
    }

    enum Period: CaseIterable {
        case today, yesterday, earlier

        var title: String {
            switch self {
            case .today: "今天"
            case .yesterday: "昨天"
            case .earlier: "更早"
            }
        }
    }

    struct DateSection {
        let period: Period
        let entries: [ScreenshotArchiveEntry]
    }

    func dateSections(now: Date = Date(), calendar: Calendar = .current) -> [DateSection] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let grouped = Dictionary(grouping: entries) { entry -> Period in
            if calendar.isDate(entry.date, inSameDayAs: today) { return .today }
            if let yesterday, calendar.isDate(entry.date, inSameDayAs: yesterday) { return .yesterday }
            return .earlier
        }
        return Period.allCases.compactMap { period in
            grouped[period].map { DateSection(period: period, entries: $0) }
        }
    }
}

/// The archive includes old media that may have gone missing or been replaced since import.
/// Read from one no-follow descriptor and decode only the bytes matching Riftlet's manifest.
actor ScreenshotArchiveMedia {
    static let shared = ScreenshotArchiveMedia()

    private func verifiedSource(_ image: ImportedAsset, root: URL) -> CGImageSource? {
        guard !Task.isCancelled, image.byteCount > 0,
              image.byteCount <= ScreenshotImportLimits.bytes, !image.fileName.isEmpty,
              image.fileName != ".", image.fileName != "..",
              !image.fileName.contains("/"), !image.fileName.utf8.contains(0) else { return nil }
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let rootFD = open(root.path, directoryFlags)
        guard rootFD >= 0 else { return nil }
        defer { close(rootFD) }
        let mediaFD = openat(rootFD, "media", directoryFlags)
        guard mediaFD >= 0 else { return nil }
        defer { close(mediaFD) }
        let file = openat(mediaFD, image.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == image.byteCount, info.st_nlink == 1,
              let bytes = try? handle.read(upToCount: Int(info.st_size)),
              bytes.count == info.st_size,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == image.sha256,
              !Task.isCancelled,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return source
    }

    func verifiedDimensions(_ image: ImportedAsset, root: URL) -> CGSize? {
        guard let source = verifiedSource(image, root: root), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    func preview(_ image: ImportedAsset, root: URL, pixels: Int) -> CGImage? {
        guard pixels > 0, let source = verifiedSource(image, root: root) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(pixels, 1536),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
