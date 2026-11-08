import Foundation
import RiftletCore

/// Headless validation uses the exact admission policy of the connected product library.
public enum TestReceiptPolicy {
    public static func admits(_ data: Data) throws -> Bool {
        struct Evidence: Decodable { let asset: ImportedAsset; let start, final: TransferReceipt; let invocationID: UUID }
        let e = try JSONDecoder().decode(Evidence.self, from: data)
        let policy = OrdinaryCaptureConfiguration.admission.receiptPolicy
        return e.start.operationID == e.final.operationID && e.start.assetID == e.asset.id && e.final.assetID == e.asset.id
            && e.start.assetSHA256 == e.asset.sha256 && e.final.assetSHA256 == e.asset.sha256
            && e.start.attempt == 1 && e.final.attempt == 1 && e.start.target == e.final.target
            && e.start.attachmentID == e.final.attachmentID && e.final.completionEvidence?.binding.invocationID == e.invocationID
            && policy.allowsUploadStart(receipt: e.start, asset: e.asset, mode: .production)
            && policy.allowsConsumption(receipt: e.final, asset: e.asset, mode: .production)
    }
}
