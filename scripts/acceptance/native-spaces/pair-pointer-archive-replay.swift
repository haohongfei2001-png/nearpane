// Read one existing signed-fixture movie to cross-check the full-display-to-ROI transform offline.
import AVFoundation
import CryptoKit

@main
struct PairPointerArchiveReplay {
    struct InvalidReceipt: Error {}
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw InvalidReceipt() }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func json(_ name: String) throws -> [String: Any] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InvalidReceipt() }
            return object
        }
        func rect(_ values: [Double]) -> CGRect? {
            guard values.count == 4, values.allSatisfy(\.isFinite) else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        let film = try json("right-drag-film.json"), manifest = try json("installed-manifest.json")
        let pointer = try json("pair-pointer.json")
        let movie = directory.appendingPathComponent("right-drag-fixture-windows.mp4")
        let hash = SHA256.hash(data: try Data(contentsOf: movie)).map { String(format: "%02x", $0) }.joined()
        guard film["status"] as? String == "CAPTURED", film["source"] as? String == "SCContentFilter(display:including:twoRegisteredWindows)",
              film["noAudio"] as? Bool == true, film["sha256"] as? String == hash,
              let fixture = film["fixtureHash"] as? String, (pointer["fixtureSigning"] as? [String: Any])?["CDHash"] as? String == fixture,
              let observed = manifest["observed"] as? [String: Any], let displays = observed["displays"] as? [[String:Any]], displays.count == 1,
              let displayID = displays[0]["uuid"] as? String, film["displayUUID"] as? String == displayID,
              let geometry = displays[0]["bounds"] as? [Double], let display = rect(geometry),
              let sources = film["sourceFrames"] as? [[Double]], sources.count == 2,
              let a = rect(sources[0]), let b = rect(sources[1]), let overlap = PairVisualEvidence.crop(frames:[a,b], display:display),
              let rows = film["frames"] as? [[String:Any]], let down = film["mouseDownUptime"] as? Double else { throw InvalidReceipt() }

        func exclusive(_ window: CGRect, other: CGRect) -> CGRect? {
            let y = floor(window.minY + 0.68 * window.height)
            for x in stride(from:ceil(window.minX+12), through:floor(window.maxX-20), by:4) {
                let r = CGRect(x:x, y:y, width:8, height:8)
                if window.insetBy(dx:12,dy:12).contains(r), !r.intersects(other.insetBy(dx:-3,dy:-3)) { return r }
            }
            return nil
        }
        guard let aOnly = exclusive(a,other:b), let bOnly = exclusive(b,other:a) else { throw InvalidReceipt() }
        let encoded = rows.filter { $0["encoded"] as? Bool == true }
        let asset = AVURLAsset(url:movie), tracks = try await asset.loadTracks(withMediaType:.video)
        let audio = try await asset.loadTracks(withMediaType:.audio)
        guard tracks.count == 1, audio.isEmpty else { throw InvalidReceipt() }
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw InvalidReceipt() }
        var index = 0, rowsBefore = [[String:Any]]()
        while let sample = output.copyNextSampleBuffer() {
            guard encoded.indices.contains(index), let t = encoded[index]["displayTime"] as? Double,
                  let image = sample.imageBuffer, let format = sample.formatDescription,
                  CVPixelBufferGetWidth(image) == film["width"] as? Int, CVPixelBufferGetHeight(image) == film["height"] as? Int else { throw InvalidReceipt() }
            defer { index += 1 }
            guard t < down else { continue } // afterward the enrolled geometry moves during the drag
            let clean = CMVideoFormatDescriptionGetCleanAperture(format,originIsAtTopLeft:true)
            let reads = [aOnly,bOnly,overlap].map { PairFocusRaster.measure(image,display:display,crop:$0,clean:clean,minimumSide:1) }
            rowsBefore.append(["index":index, "sourceSlots":reads.map { $0.slot ?? -1 }, "numericRasters":reads.map(\.record)])
        }
        guard reader.status == .completed, index == encoded.count else { throw InvalidReceipt() }
        let qualified = !rowsBefore.isEmpty && rowsBefore.allSatisfy {
            guard let slots = $0["sourceSlots"] as? [Int] else { return false }
            return slots[0] == 0 && slots[1] == 1 && (0...1).contains(slots[2])
        }
        let result: [String:Any] = [
            "archivedMapping": qualified ? "CORROBORATED" : "UNKNOWN", "sha256": hash, "source": "H264 encoded after an opaque matte",
            "displayPoints": geometry, "decodedFrames": index, "preDragSamples":rowsBefore,
            "declaredFixtureCDHash":fixture, "retainedPixelBytes":0,
            "focusLatency":"UNKNOWN (drag movie, no paired focus click)", "originalBufferAlpha":"UNKNOWN (matted video)",
            "resolution":"archive uses all whole pixels in each 8-point crop; live acceptance requires at least 8 by 8 actual pixels"]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
}
