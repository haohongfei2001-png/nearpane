import AppKit
import RiftletCore
import UniformTypeIdentifiers

extension TrayModule {
    /// Copy and drag always use the full original, never the grid thumbnail.
    @discardableResult func copyArchiveImage(_ asset: ImportedAsset, session: UUID,
                                            pasteboard: NSPasteboard = .general) async -> Bool {
        guard let data = await archiveOriginalData(asset, session: session),
              let image = NSImage(data: data) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    func archiveDragProvider(_ asset: ImportedAsset, session: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = URL(fileURLWithPath: asset.fileName).lastPathComponent
        let type = UTType(mimeType: asset.mediaType) ?? .image
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { [weak self] completion in
            Task { @MainActor in
                guard let data = await self?.archiveOriginalData(asset, session: session) else {
                    completion(nil, CocoaError(.fileReadCorruptFile)); return
                }
                // The manifest already identifies the original format. Passing it
                // through avoids decoding/re-encoding a large capture on the UI actor.
                completion(data, nil)
            }
            return nil
        }
        return provider
    }
}
