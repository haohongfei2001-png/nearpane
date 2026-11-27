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
        provider.suggestedName = URL(fileURLWithPath: asset.fileName).deletingPathExtension().lastPathComponent + ".png"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { [weak self] completion in
            Task { @MainActor in
                guard let data = await self?.archiveOriginalData(asset, session: session),
                      let bitmap = NSBitmapImageRep(data: data),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    completion(nil, CocoaError(.fileReadCorruptFile)); return
                }
                completion(png, nil)
            }
            return nil
        }
        return provider
    }
}
