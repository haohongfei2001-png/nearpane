import CryptoKit
import Darwin
import Foundation
import RiftletAdapters
import RiftletCore

private enum FixtureError: Error { case invalid, refused }
private struct Request: Decodable {
  let folder, browserID, host: String
  let pid: Int32
  let intentID: UUID
}

@MainActor final class HeadlessDraftPipe: WebClickTargetPinning {
  let route: DraftQualificationRoute
  init(_ route: DraftQualificationRoute) { self.route = route }
  func evaluate(_ source: String, command: Any) throws -> Data {
    let json = try JSONSerialization.data(withJSONObject: ["source": source, "command": command])
    FileHandle.standardOutput.write(json + Data([10]))
    guard let line = readLine(),
      let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let result = value["result"] as? String
    else { throw FixtureError.refused }
    return Data(result.utf8)
  }
  func targetForClick(program: WebPageProgram) throws -> Task<TargetLease, Error> {
    guard program.qualification == route, let pin = program.pinSource else {
      throw FixtureError.invalid
    }
    let id = UUID().uuidString
    let address = "https://" + route.service.rawValue + route.service.freshPath
    guard
      try String(
        decoding: evaluate(
          pin, command: ["action": "pinTarget", "clickWitnessID": id, "address": address]),
        as: UTF8.self) == "bound"
    else {
      throw FixtureError.refused
    }
    let target = try JSONDecoder().decode(
      TargetLease.self,
      from: evaluate(
        program.functionSource, command: ["action": "captureTarget", "clickWitnessID": id]))
    guard target.applicationID == route.browser.rawValue, target.adapterID == route.adapterID,
      target.clickBindingID == UUID(uuidString: id)
    else { throw FixtureError.invalid }
    return Task { target }
  }
  func execute(_ command: WebBridgeCommand, program: WebPageProgram) async throws -> Data {
    guard program.qualification == route else { throw FixtureError.refused }
    return try evaluate(
      program.functionSource,
      command: JSONSerialization.jsonObject(with: JSONEncoder().encode(command)))
  }
}

@main struct Driver {
  @MainActor static func main() async throws {
    guard let line = readLine() else { throw FixtureError.invalid }
    let args = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
    guard let browser = DraftBrowser(rawValue: args.browserID), browser.hasStableTabID,
      browser.signed(pid: args.pid),
      let service = QualificationDraftService(rawValue: args.host)
    else { throw FixtureError.invalid }
    let base = URL(fileURLWithPath: args.folder, isDirectory: true).standardizedFileURL
    let checkout = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .standardizedFileURL
    let browserFolder = base.deletingLastPathComponent()
    let scratch = browserFolder.deletingLastPathComponent()
    guard base == base.resolvingSymlinksInPath(),
      browserFolder.lastPathComponent.hasPrefix("local-browser-"),
      scratch.lastPathComponent.hasPrefix("p3-qualified-"),
      scratch.deletingLastPathComponent().path == checkout.appendingPathComponent("build").path
    else { throw FixtureError.invalid }
    var info = proc_bsdinfo()
    let count = Int32(MemoryLayout.size(ofValue: info))
    guard proc_pidinfo(args.pid, PROC_PIDTBSDINFO, 0, &info, count) == count,
      info.pbi_uid == getuid(),
      info.pbi_start_tvsec > 0
    else { throw FixtureError.invalid }
    let session =
      (browser == .chrome ? "chrome" : "edge") + "-kernel-v1:" + String(args.pid) + ":"
      + String(info.pbi_start_tvsec)
      + ":" + String(info.pbi_start_tvusec)
    let address = URL(string: "https://" + service.rawValue + service.freshPath)!
    let route = try DraftAttachmentQualification.route(
      browserID: args.browserID, selectedURL: address)
    let transport = HeadlessDraftPipe(route)
    let media = base.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(
      at: media, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let id = UUID()
    let png = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGNQ91/l1DGH4cwql/K0UAAk9wVzjPxe1gAAAABJRU5ErkJggg=="
    )!
    let file = media.appendingPathComponent(id.uuidString + ".png")
    try png.write(to: file, options: .withoutOverwriting)
    let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    let image = ImportedAsset(
      id: id, sourceKey: id.uuidString, fileName: file.lastPathComponent, sha256: hash,
      byteCount: Int64(png.count), pixelWidth: 2, pixelHeight: 2, mediaType: "image/png",
      origin: .synthetic)
    let store = try QueueStore(databaseURL: base.appendingPathComponent("queue.sqlite"))
    _ = try await store.importAsset(image)
    let adapter = try DraftAttachmentQualification.adapter(route, media: media, executor: transport)
    let notAdmitted = WebAttachmentAdapter(
      mediaDirectory: media, executor: transport, program: try route.program(),
      mode: .ordinaryProduct,
      profile: route.profile)
    do {
      _ = try notAdmitted.targetForClick()
      throw FixtureError.invalid
    } catch WebAdapterError.disabled {}
    var result: [String: Any] = [
      "done": true, "ordinaryWriterRefused": true, "sha256": hash, "assetID": id.uuidString,
      "intentID": args.intentID.uuidString, "adapterID": route.adapterID, "processSession": session,
      "sourceByteCount": png.count,
    ]
    // The pipe receives only the immutable identities of the headless child, its synthetic window and one enrolled tab.
    FileHandle.standardOutput.write(
      try JSONSerialization.data(withJSONObject: ["session": session]) + Data([10]))
    guard readLine() == "ok" else { throw FixtureError.invalid }
    do {
      let selected = try await adapter.targetForClick().value
      guard selected.sessionID == session, selected.windowID == "1", selected.tabID == "1" else {
        throw FixtureError.invalid
      }
      result["targetPinned"] = true
      result["documentID"] = selected.documentID
      result["composerID"] = selected.composerID
      result["draftGeneration"] = selected.draftGeneration
      result["clickBindingID"] = selected.clickBindingID?.uuidString
      let prepared = try await store.prepare(assetID: id, target: selected)
      result["operationID"] = prepared.id.uuidString
      let invocation = try await store.markDispatchIntent(prepared.id)
      guard let operation = try await store.operation(id: prepared.id) else {
        throw FixtureError.invalid
      }
      let req = TransferRequest(
        operation: operation, asset: image, fileURL: file, invocationID: invocation)
      let privateOrigin = ImportedAsset(
        id: id, sourceKey: id.uuidString, fileName: file.lastPathComponent, sha256: hash,
        byteCount: Int64(png.count), pixelWidth: 2, pixelHeight: 2, mediaType: "image/png",
        origin: .systemScreenshot
      )
      do {
        _ = try await adapter.append(
          .init(operation: operation, asset: privateOrigin, fileURL: file, invocationID: invocation)
        )
        throw FixtureError.invalid
      } catch WebAdapterError.syntheticAssetsOnly { result["nonSyntheticRefused"] = true }
      let receipt = try await adapter.append(req)
      result["receipt"] = receipt.outcome.rawValue
      result["receiptMatches"] =
        receipt.assetID == id && receipt.assetSHA256 == hash && receipt.target == selected
        && receipt.operationID == operation.id
      do {
        _ = try await adapter.append(req)
        throw FixtureError.invalid
      } catch WebAdapterError.invalidRequest { result["duplicateRefused"] = true }
    } catch let error as FixtureError {
      result["refused"] = true
      result["errorType"] = String(describing: error)
    } catch let error as WebAdapterError {
      result["refused"] = true
      result["errorType"] = String(describing: error).prefix(90).description
    } catch {
      result["refused"] = true
      result["errorType"] = String(describing: type(of: error))
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result) + Data([10]))
  }
}
