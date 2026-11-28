import AppKit
import Foundation
import NearpaneCore

/// Completes only the still-present, untouched overview documented by a prior witness. Never opens an overview.
@main struct FinishPresented {
    @MainActor static func main() async throws {
        umask(0o077)
        let args = CommandLine.arguments
        guard args.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let prior = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[1]))) as? [String:Any]
        let dir = URL(fileURLWithPath:args[2],isDirectory:true)
        guard try FileManager.default.contentsOfDirectory(atPath:dir.path).isEmpty else { throw CocoaError(.fileWriteFileExists) }
        var log: [String:Any] = ["status":"UNKNOWN","stage":"continuationOfUndismissedOverview","presentations":0,"dismissals":0,
            "startedUTC":ISO8601DateFormatter().string(from:Date()),"inputEventsPosted":0,"windowWrites":0,"spaceWrites":0,
            "retainedPrePresentationAXAvailable":false]
        defer {
            log["endedUTC"] = ISO8601DateFormatter().string(from:Date())
            if let data = try? JSONSerialization.data(withJSONObject:log,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:dir.appendingPathComponent("continuation.json"),options:.withoutOverwriting)
            }
        }
        guard let prior, let probe = prior["measurement"] as? [String:Any], let subject = prior["host"] as? [String:Any],
              let pid = subject["pid"] as? Int32, let birth = subject["birth"] as? UInt64,
              let original = probe["originalFocus"] as? [String:Any], let front = original["pid"] as? Int32,
              let generation = original["birth"] as? UInt64, let hardware = probe["hidBefore"] as? [UInt32], hardware.count == 14,
              hardware == probe["hidAfter"] as? [UInt32], probe["presentations"] as? Int == 1, probe["dismissals"] as? Int == 0,
              let managed = probe["managedIDsBefore"] as? [UInt64], managed == probe["managedIDsAfter"] as? [UInt64],
              let geometry = (probe["hitTestSamples"] as? [[String:Any]])?.first?["displayFrame"] as? [Double],
              let source = (prior["hostTelemetry"] as? [[String:Any]])?.last, source["missionControlObservation"] as? String == "signedDockMCIdentifier"
        else { log["reason"] = "noOwnedUndismissedOverview"; return }
        let digest = try OrdinaryProcessImage.signingDigest(pid).map{String(format:"%02x",$0)}.joined()
        let fixed = "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost"
        let host = try OrdinaryProcessImage.read(pid), dock = try StageCanaryOverview.signedDock()
        guard host.launch == birth, host.executable.path == fixed, digest == subject["cdhash"] as? String,
              try OrdinaryProcessImage.read(front).launch == generation else { log["reason"] = "generationChanged"; return }
        func rows() -> [UInt64]? {
            guard let r = try? StageCanaryOverview.inventory(), let sets = r.first?["Spaces"] as? [NSDictionary] else { return nil }
            return sets.compactMap{ $0["ManagedSpaceID"] as? UInt64 }
        }
        func untouched() -> Bool { StageCanaryOverview.hid() == hardware && NSEvent.pressedMouseButtons == 0 }
        func owned() -> Bool {
            untouched() && (try? OrdinaryProcessImage.read(pid)) == host && NSScreen.screens.count == 1 &&
            StageOverviewHitTest.box(CGDisplayBounds(CGMainDisplayID())) == geometry && rows() == managed
        }
        log["hidAtEntry"] = StageCanaryOverview.hid()
        guard owned(), let open = try StageCanaryOverview.root(dock) else {
            log["reason"] = "overviewAlreadyClosedOrInputScopeChanged"; return
        }
        let media = OverviewMedia(dir)
        await media.start()
        var samples = [StageOverviewHitTest.Sample]()
        for _ in 0..<2 {
            guard owned(), try StageCanaryOverview.root(dock) == open else { break }
            samples.append(StageOverviewHitTest.sample(dock:dock.app,dockPID:dock.image.pid,
                bounds:CGDisplayBounds(CGMainDisplayID()),inputUnchanged:untouched))
            try await Task.sleep(for:.milliseconds(100))
        }
        log["samples"] = samples.map(\.evidence)
        log["stablePhysicalLayouts"] = samples.count == 2 && samples.allSatisfy(\.complete) &&
            samples[0].tiles.count == managed.count && samples[0].tiles == samples[1].tiles &&
            !samples[0].visibleRow.isEmpty && samples[0].visibleRow == samples[1].visibleRow &&
            StageOverviewHitTest.validLayout(samples[0].tiles.map(\.frame),in:CGDisplayBounds(CGMainDisplayID()))
        if owned(), try StageCanaryOverview.root(dock) == open {
            log["dismissals"] = 1
            try StageCanaryOverview.toggle()
            var observations = [[String:Any]]()
            for _ in 0..<18 {
                try await Task.sleep(for:.milliseconds(130))
                guard untouched() else { break }
                let row = StageCanaryOverview.admission()
                observations.append(row)
                if observations.suffix(2).count == 2 && observations.suffix(2).allSatisfy({ r in
                    r["workspacePID"] as? Int32 == front && r["birth"] as? UInt64 == generation && r["cgWindowID"] as? UInt32 == original["window"] as? UInt32
                }) { break }
            }
            log["focusAfter"] = observations
        }
        log["media"] = await media.finish()
        log["hidAfter"] = StageCanaryOverview.hid()
        log["managedIDsAfter"] = rows()
        do {
            let closed = try StageCanaryOverview.root(dock) == nil
            log["overviewClosed"] = closed
            log["status"] = closed && rows() == managed && untouched() ? "PASS" : "UNKNOWN"
        } catch { log["reason"] = "terminalSystemRootUnavailable" }
    }
}
