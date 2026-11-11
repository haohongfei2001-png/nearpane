// Linked to the built product modules. Only the native Chrome-address transport is replaced.
import Foundation
import CryptoKit
import Darwin
import RiftletCore
import RiftletAdapters
@testable import NearpaneTray

struct FixtureError: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

@MainActor private final class PipeTransport: WebClickTargetPinning {
    func request(_ value: [String:Any]) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject:value)
        FileHandle.standardOutput.write(bytes + Data([10]))
        guard let line = readLine(), let json = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],
              let data = json["result"] as? String else { throw FixtureError("Fixture refused the original destination") }
        return Data(data.utf8)
    }
    func targetForClick(program: WebPageProgram) throws -> Task<TargetLease, Error> {
        let bytes = try request(["cmd":"invoke", "command":["action":"captureTarget"], "source":program.functionSource])
        let target = try JSONDecoder().decode(TargetLease.self, from: bytes)
        return Task { target }
    }
    func execute(_ command: WebBridgeCommand, program: WebPageProgram) async throws -> Data {
        try request(["cmd":"invoke", "source":program.functionSource,
                     "command":JSONSerialization.jsonObject(with:JSONEncoder().encode(command))])
    }
}

@main struct ProductBrowserDriver {
    /// Only read the queue and the displayed field. Product callbacks remain responsible for updating the field.
    @MainActor static func observeUnknown(_ id: UUID, in store: QueueStore, module: TrayModule) async throws -> [[String:Any]] {
        let start = DispatchTime.now().uptimeNanoseconds
        var firstUnknown: UInt64?
        var last: [String:String]?
        var samples: [[String:Any]] = []
        while true {
            let before = module.attachmentFeedback ?? ""
            guard let row = try await store.asset(id:id), let oid = row.activeOperationID,
                  let op = try await store.operation(id:oid) else { throw FixtureError("original operation absent") }
            let after = module.attachmentFeedback ?? ""
            let time = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let state = ["status":row.status.rawValue, "phase":op.phase.rawValue, "uiBeforeRead":before, "uiAfterRead":after]
            let unknown = row.status == .unknown && op.phase == .unknown
            if unknown && firstUnknown == nil { firstUnknown = time }
            if state != last {
                var sample: [String:Any] = state
                sample["operation"] = oid.uuidString.lowercased()
                sample["attempt"] = op.attempt
                sample["elapsedMS"] = time
                samples.append(sample)
                last = state
            }
            if let firstUnknown, time - firstUnknown >= 3000 || (unknown && before.contains("结果未知") && before == after) {
                return samples
            }
            guard time < 12000 else { throw FixtureError("original dispatch never reached UNKNOWN") }
            try await Task.sleep(for:.milliseconds(15))
        }
    }

    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, let line = readLine(),
              let settings = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String:Any],
              let id = (settings["assetID"] as? String).flatMap(UUID.init(uuidString:)),
              let expected = settings["sha256"] as? String, let pid = settings["chromePID"] as? Int32,
              let width = settings["width"] as? Int, let height = settings["height"] as? Int,
              let origin = (settings["origin"] as? String).flatMap(AssetOrigin.init(rawValue:)) else { throw FixtureError("arguments") }
        let base = URL(fileURLWithPath:args[2], isDirectory:true).standardizedFileURL
        guard base.path.hasPrefix(FileManager.default.currentDirectoryPath + "/build/local-browser-"), base == base.resolvingSymlinksInPath() else {
            throw FixtureError("test directory")
        }
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let media = base.appendingPathComponent("media")
        let mediaFile = media.appendingPathComponent(id.uuidString + ".png")
        let data = try Data(contentsOf:mediaFile)
        guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == expected else { throw FixtureError("file hash") }
        let asset = ImportedAsset(id:id, sourceKey:"p50-generated-fixture-" + id.uuidString, fileName:mediaFile.lastPathComponent,
            sha256:expected, byteCount:Int64(data.count), pixelWidth:width, pixelHeight:height, mediaType:"image/png", origin:origin)
        let store = try QueueStore(databaseURL:base.appendingPathComponent("queue.sqlite"), mode:.production)
        if args[3] == "click" { _ = try await store.importAsset(asset) }
        let pipe = PipeTransport()
        var process = proc_bsdinfo(), executable = [CChar](repeating:0,count:4096)
        let size=Int32(MemoryLayout.size(ofValue:process))
        guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&process,size)==size, process.pbi_pid==UInt32(pid),
              process.pbi_uid==getuid(), process.pbi_start_tvsec>0,
              proc_pidpath(pid,&executable,UInt32(executable.count))>0,
              String(cString:executable)=="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" else { throw FixtureError("headless process birth") }
        let proc="chrome-kernel-v1:\(pid):\(process.pbi_start_tvsec):\(process.pbi_start_tvusec)"
        _ = try pipe.request(["cmd":"process", "value":proc])
        let source = try String(contentsOfFile:args[1], encoding:.utf8)
        let locked = WebPageProgram(sourceID:ChatGPTWebPageProgram.sourceID, functionSource:source,
            maximumChunkBytes:256 * 1024, inputDiscoveryTimeout:3)
        let guardSource = try String(contentsOf:root.appendingPathComponent("build/debug/Nearpane.app/Contents/Resources/AcceptanceTargetGuard.js"), encoding:.utf8)
        let bound = ProductDraftExecutor(root:base, base:pipe, guardSource:guardSource, arm:{ image in
            let now = Date().timeIntervalSince1970
            let nonce = UUID().uuidString.lowercased()
            func binding(_ timeOrigin: Double) -> ProductDraftBinding {
                ProductDraftBinding(nonce:nonce, process:proc, window:"1", tab:"1", assetID:image.id.uuidString.lowercased(),
                    sha256:image.sha256, boundAt:now, expiresAt:now+60, timeOrigin:timeOrigin)
            }
            let script = try ProductDraftBinding.armScript(draft:binding(0), guardSource:guardSource)
            let raw = try pipe.request(["cmd":"arm","script":script])
            guard let result = try JSONSerialization.jsonObject(with:raw) as? [String:Any], let origin=result["timeOrigin"] as? Double else {
                throw FixtureError("composer refused")
            }
            return binding(origin)
        }, selected:{ _ in _ = try pipe.request(["cmd":"selected"]) })
        let policy = OrdinaryCaptureConfiguration.admission
        let adapter = WebAttachmentAdapter(mediaDirectory:media, executor:bound, program:locked, mode:.ordinaryProduct,
            profile:policy.observationProfile, productStore:store, productOrigins:policy.productOrigins)
        let module = TrayModule(productAttachments:true) { notify, report in
            let owner = TrayOwner(store:store, root:base, adapter:adapter, policy:policy.receiptPolicy, captureEntry:false,
                                  pin:{ try adapter.targetForClick() }, permission:{ _,_ in true }, notify:notify, report:report)
            owner.checkAsset = { try bound.checkAsset($0) }
            owner.cancelDraftSelections = { bound.cancelSelections() }
            return owner
        }
        try module.start()
        await module.connect()
        guard module.connected else { throw FixtureError("isolated library did not connect") }
        if args[3] == "click" {
            guard !module.mayAttach else { throw FixtureError("new library consent") }
            await module.authorizeAttachments()
        }
        guard module.mayAttach else { throw FixtureError("attachment consent") }
        var liveSamples: [[String:Any]]?
        if args[3] != "restart" {
            guard let row = module.rows.first, row.id == id else { throw FixtureError("missing queue row") }
            if let press = module.beginPress(row) {
                await module.finishPress(press)
            }
            // Current-click input runs independently after the coordinator durably records its intent.
            // Keep the host connected until the original dispatch settles, as a user waiting in the tray would.
            if settings["measureLiveFeedback"] as? Bool == true {
                liveSamples = try await observeUnknown(id, in:store, module:module)
            } else {
                let deadline = ContinuousClock.now.advanced(by:.seconds(12))
                while let record = try await store.asset(id:id), record.status == .transferring {
                    if let oid = record.activeOperationID, try await store.uploadStartReceipt(for:oid) != nil { break }
                    guard ContinuousClock.now < deadline else { throw FixtureError("original dispatch never settled") }
                    try await Task.sleep(for:.milliseconds(35))
                }
                await module.refresh()
            }
        }
        let issue = module.issue
        let feedback = module.attachmentFeedback
        module.stop()
        await module.finishStopping()
        let result = try await store.asset(id:id)
        var final: [String:Any] = ["cmd":"done","status":result?.status.rawValue ?? "missing", "assetID":id.uuidString.lowercased(), "driverPID":getpid()]
        if let issue { final["issue"] = issue }
        if let feedback { final["feedback"] = feedback }
        if let liveSamples { final["liveSamples"] = liveSamples }
        if let oid = result?.activeOperationID, let op = try await store.operation(id:oid) {
            final["operation"] = oid.uuidString.lowercased()
            final["phase"] = op.phase.rawValue
            final["attempt"] = op.attempt
            final["start"] = try await store.uploadStartReceipt(for:oid)?.outcome.rawValue
            final["receipt"] = try await store.receipt(for:oid)?.outcome.rawValue
        }
        _ = try pipe.request(final)
    }
}
