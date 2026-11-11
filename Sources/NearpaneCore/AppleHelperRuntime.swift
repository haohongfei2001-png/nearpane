import Foundation
import Security

/// Running /usr/bin/python3 on a clean Mac can open the developer tools installer.
/// Use only an already installed Apple interpreter; never search PATH or start an installer.
public enum AppleHelperRuntime {
    public enum Missing: LocalizedError {
        case interpreter
        public var errorDescription: String? {
            "未找到可验证的 Apple Python。此 Alpha 的窗口管理和资料导入需要已安装的 Command Line Tools 或标准位置的 Xcode。Nearpane 不会安装工具或改动窗口、资料。"
        }
    }

    public static let python: URL? = {
        let flags = SecCSFlags()
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("identifier \"com.apple.python3\" and anchor apple" as CFString,
                                             flags, &requirement) == errSecSuccess, let requirement else { return nil }
        let candidates = ["/Library/Developer/CommandLineTools/usr/bin/python3",
                          "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
        for path in candidates {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            var code: SecStaticCode?
            if SecStaticCodeCreateWithPath(url as CFURL, flags, &code) == errSecSuccess, let code,
               SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess { return url }
        }
        return nil
    }()
}
