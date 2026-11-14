import CryptoKit
import Foundation
import Security

/// Only the fixed entry points and code sealed into this copy of Nearpane may run.
public enum BundledAutomation {
    public enum Missing: LocalizedError {
        case runtime
        public var errorDescription: String? {
            "无法核验 Nearpane 随附的窗口与资料工具。请恢复完整的 Nearpane 应用后重试。"
        }
    }

    public static func executable(in bundle: Bundle = .main) throws -> URL {
        let paths = ["Helpers/NearpaneAutomation", "Resources/Automation/stdlib.zip",
                     "Resources/Profile/profile-migration.py", "Resources/Profile/profile_domains.py",
                     "Resources/WorkRect/window-management.py"]
        guard let expected = bundle.object(forInfoDictionaryKey: "NearpaneAutomationSHA256") as? [String: String],
              Set(expected.keys) == Set(paths), bundle.bundleURL.pathExtension == "app" else { throw Missing.runtime }
        let contents = bundle.bundleURL.resolvingSymlinksInPath().appendingPathComponent("Contents")
        for path in paths {
            let url = contents.appendingPathComponent(path)
            guard url.path == url.resolvingSymlinksInPath().path,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let bytes = try? Data(contentsOf: url, options: .mappedIfSafe),
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected[path]
            else { throw Missing.runtime }
        }
        let executable = contents.appendingPathComponent(paths[0])
        var code: SecStaticCode?
        let flags = SecCSFlags()
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              SecStaticCodeCreateWithPath(executable as CFURL, flags, &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw Missing.runtime }
        return executable
    }
}
