import AppKit

enum FivePreviewWindow {
    static func identifier(_ slot: Int) -> String { "net.example.nearpane-five-preview." + String(slot + 1) }
    static func frame(slot: Int, in frame: CGRect) -> CGRect {
        let width = min(370, floor(frame.width * 0.26)), height = min(108, floor(frame.height * 0.16))
        return CGRect(x: floor(frame.midX + (slot % 2 == 0 ? -width - 8 : 8)),
                      y: floor(frame.midY + CGFloat(1 - slot / 2) * (height + 38) - height / 2),
                      width: width, height: height)
    }
    static func color(slot: Int, phase: Int) -> NSColor {
        let rgb = PairedPreviewPalette.epochs[slot][phase].map { CGFloat($0) / 255 }
        return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
    }
}

struct FivePreviewMarker: Decodable {
    let session: String, pid: pid_t, birth: UInt64, number: Int, slot: Int, phase: Int
    let issued: Double
    func matches(session: String, pid: pid_t, birth: UInt64, number: Int, slot: Int) -> Bool {
        let age = ProcessInfo.processInfo.systemUptime - issued
        return self.session == session && self.pid == pid && self.birth == birth &&
            self.number == number && self.slot == slot && phase == 1 && age >= 0 && age <= 12
    }
}

func PreviewFixtureDirectory(_ run: URL) -> URL? {
    let parent = run.deletingLastPathComponent()
    guard parent.deletingLastPathComponent().path == "/private/tmp", parent.lastPathComponent.hasPrefix("nearpane-five."),
          UUID(uuidString: run.lastPathComponent) != nil else { return nil }
    for url in [parent, run, parent.appendingPathComponent("home")] {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o177777 == 0o40700 else { return nil }
    }
    return parent
}
