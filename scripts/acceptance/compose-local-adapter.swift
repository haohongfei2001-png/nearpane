// Built against the verified debug modules by the offline browser fixture.
import Foundation
import RiftletAdapters
@testable import NearpaneTray

@main struct ComposeLocalAdapter {
    static func main() throws {
        let binding = try JSONDecoder().decode(TestTargetBinding.self, from: FileHandle.standardInput.readDataToEndOfFile())
        try binding.check(session: binding.session, now: Date().timeIntervalSince1970)
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = try String(contentsOf: input, encoding: .utf8)
        let guardSource = try String(contentsOf: base.appendingPathComponent("Resources/AcceptanceTargetGuard.js"), encoding: .utf8)
        let locked = WebPageProgram(sourceID: ChatGPTWebPageProgram.sourceID, functionSource: source,
                                    maximumChunkBytes: 256 * 1024, inputDiscoveryTimeout: 3)
        let guarded = try binding.program(locked, guardSource: guardSource)
        FileHandle.standardOutput.write(Data(guarded.functionSource.utf8))
    }
}
