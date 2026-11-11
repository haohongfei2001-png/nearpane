import Foundation
import RiftletCore

extension TrayOwner {
    /// Read the last explicitly selected screenshot, including a row swallowed at START.
    /// The persisted UI cursor only selects a receipt to display. It never feeds transfer.select.
    func feedback(for assetID: UUID, live: Bool) async throws -> String? {
        guard let asset = try await store.asset(id: assetID),
              let active = asset.activeOperationID, let op = try await store.operation(id: active),
              op.assetID == asset.id else { return nil }
        let prefix = "截图 " + String(asset.sequence) + " · "
        switch op.phase {
        case .succeeded:
            guard let receipt = try await store.receipt(for: op.id), asset.status == .used,
                  receipt.outcome == .verifiedReady, receipt.operationID == op.id, receipt.assetID == asset.id,
                  receipt.attempt == op.attempt, receipt.target == op.target, receipt.assetSHA256 == asset.image.sha256,
                  receiptPolicy.allowsConsumption(receipt: receipt, asset: asset.image, mode: await store.mode)
            else { return prefix + "缺少对应完成回执，请核对原草稿。" }
            return prefix + "已附加到草稿；Nearpane 未发送消息。"
        case .failed:
            return prefix + "附加失败，请核对原草稿。"
        case .compensated, .unknown:
            return prefix + "结果未知，请核对原草稿。"
        case .prepared, .dispatchIntent, .inputTriggered, .attachmentPresent:
            if try await store.uploadStartReceipt(for: op.id) != nil {
                return prefix + "已开始上传，尚无完成回执。"
            }
            return prefix + (live ? "正在处理附件…" : "上次附加没有完成回执，请核对原草稿。")
        }
    }
}
