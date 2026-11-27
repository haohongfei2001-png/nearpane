// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The wrappers authenticate the pinned inputs before SwiftPM reads them.
let full = Context.environment["NEARPANE_FOUNDATION_ONLY"] != "1"
struct DomainPin: Decodable {
    let commit: String
    let treeSHA256: String
    let sources: [String]
    struct Adaptation: Decodable { let compiledSHA256: String }
    let captureReadiness: Adaptation?
    let draftWitness: Adaptation?
    var key: String { commit + "-" + treeSHA256 }
}
struct DomainLock: Decodable {
    let domains: [String: DomainPin]
}
let domains: [Target.Dependency] = full ? ["NearpaneVoice", "NearpaneTray", "RiftletFeedback", "NearpaneLyricsModule", "LyricUI", "LyricPlayback"] : []
let fixtureDomains: [Target.Dependency] = full ? ["SaytileKit", "RiftletCore", "RiftletCapture"] : []
let manifestRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
#if arch(arm64)
let engineTriple = "aarch64-apple-darwin"
#else
let engineTriple = "x86_64-apple-darwin"
#endif
let engineArchive = Context.environment["NEARPANE_ENGINE_ARCHIVE"]
    ?? manifestRoot.appendingPathComponent(".build/window-engine/cargo-target/" + engineTriple + "/release/libnearpane_window_engine.a").path
let engineLink: [LinkerSetting] = [.unsafeFlags([engineArchive]), .linkedLibrary("objc"),
    .linkedFramework("Foundation"), .linkedFramework("AppKit"), .linkedFramework("QuartzCore"), .linkedFramework("ApplicationServices"),
    .linkedFramework("CoreGraphics"), .linkedFramework("CoreFoundation"), .linkedFramework("Carbon"), .linkedFramework("ImageIO"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("Security")]
// The CLI keeps its own process, TCC identity and signed parent checks. StageGroup links the
// same checked AX primitives into the Host and uses its sealed in-process binding.
let ordinarySources = "Sources/NearpaneOrdinaryWindowController"
let ordinaryRuntimeSources = [
    "BoundaryChangeTracker.swift", "CreatedWindowWatch.swift", "CurrentFocusScope.swift", "FocusCurrentWindow.swift",
    "OrdinaryDesktopMembership.swift", "OwnerIdentity.swift", "PairPlacement.swift", "StageHostWindow.swift",
    "StageWindowPhysicalReader.swift", "SystemEvidence.swift", "WindowMonitor.swift"
]
var targets: [Target] = [
    .systemLibrary(name: "CNearpaneWindowEngine", path: "Engine/nearpane-window-engine/include"),
    .target(name: "NearpaneWindowEngine", dependencies: ["NearpaneCore", "CNearpaneWindowEngine"], linkerSettings: engineLink),
    .testTarget(name: "NearpaneWindowEngineTests", dependencies: ["NearpaneWindowEngine", "NearpaneCore", "CNearpaneWindowEngine"]),
    .target(name: "WindowGeometryCore"),
    .target(name: "CReadOnlySpaces", linkerSettings: [.linkedFramework("ApplicationServices")]),
    .target(name: "CNativeSpaceActions"),
    .executableTarget(name: "NearpaneSpaceAction", dependencies: ["NearpaneCore", "CReadOnlySpaces"]),
    .testTarget(name: "NearpaneSpaceActionTests", dependencies: ["NearpaneSpaceAction", "NearpaneCore", "CNativeSpaceActions"]),
    .target(name: "NearpaneCore", dependencies: ["WindowGeometryCore"]),
    .target(name: "NearpaneOrdinaryWindowRuntime", dependencies: ["NearpaneCore", "CReadOnlySpaces"],
            path: ordinarySources, exclude: ["main.swift"], sources: ordinaryRuntimeSources),
    .executableTarget(name: "NearpaneOrdinaryWindowController", dependencies: ["NearpaneCore", "NearpaneOrdinaryWindowRuntime"],
                      path: ordinarySources, exclude: ordinaryRuntimeSources, sources: ["main.swift"]),
    .executableTarget(name: "NearpaneDesktopReader", dependencies: ["NearpaneCore", "WindowGeometryCore", "CReadOnlySpaces"]),
    .target(name: "NearpaneUI", dependencies: ["NearpaneCore", "WindowGeometryCore", "NearpaneWindowEngine", "NearpaneOrdinaryWindowRuntime", "CNearpaneWindowEngine", "CReadOnlySpaces"] + domains),
    .executableTarget(name: "NearpaneHost", dependencies: ["NearpaneCore", "NearpaneUI", "NearpaneOrdinaryWindowRuntime", "NearpaneWindowEngine", "CNearpaneWindowEngine"] + (full ? ["NearpaneTray", "SaytileKit", "RiftletAdapters", "RiftletCore", "RiftletCapture", "Sparkle"] : []),
        linkerSettings: full ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] : []),
    .testTarget(name: "WindowGeometryCoreTests", dependencies: ["WindowGeometryCore"]),
    .testTarget(name: "NearpaneOrdinaryWindowControllerTests", dependencies: ["NearpaneOrdinaryWindowController", "NearpaneOrdinaryWindowRuntime"]),
    .testTarget(name: "NearpaneDesktopReaderTests", dependencies: ["NearpaneDesktopReader", "NearpaneCore"]),
    .testTarget(name: "NearpaneHostTests", dependencies: ["NearpaneHost"]),
    .testTarget(name: "NearpaneCoreTests", dependencies: ["NearpaneCore"]),
    .testTarget(name: "NearpaneUITests", dependencies: ["NearpaneUI", "NearpaneCore"] + domains + fixtureDomains)
]
if full {
    let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let lock = try JSONDecoder().decode(DomainLock.self, from: Data(contentsOf: manifest.appendingPathComponent("Dependencies/domains.lock.json")))
    guard let speech = lock.domains["saytile"], let tray = lock.domains["riftlet"] else { fatalError("Incomplete domain lock") }
    let run = Context.environment["NEARPANE_RUN_ID"] ?? ""
    let updateCache = (run.isEmpty ? ".build" : "build/standalone." + run + "/cache") + "/update-runtime/Sparkle.xcframework"
    let cache = (run.isEmpty ? ".build" : "build/standalone." + run + "/cache") + "/domain-cache-v1/"
    let saytile = cache + speech.key + "/Sources/"
    let riftlet = cache + tray.key + "/Sources/"
    guard let witness = tray.draftWitness else { fatalError("Missing Riftlet click witness bridge") }
    let voiceSuffix = speech.captureReadiness.map { "-" + $0.compiledSHA256 } ?? ""
    let lyricSources = "Products/LyricTile/Sources/"
    targets += [
        .target(name: "LyricCore", path: lyricSources + "LyricCore"),
        .target(name: "LyricServices", dependencies: ["LyricCore", .product(name: "Yams", package: "Yams")], path: lyricSources + "LyricServices"),
        .target(name: "CPlayerBridge", path: lyricSources + "CPlayerBridge", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("AppKit"), .linkedFramework("ScriptingBridge")]),
        .target(name: "LyricPlayback", dependencies: ["LyricCore", "CPlayerBridge"], path: lyricSources + "LyricPlayback"),
        .target(name: "CTileLock", path: lyricSources + "CTileLock", publicHeadersPath: "include"),
        .target(name: "TileKit", dependencies: ["CTileLock"], path: lyricSources + "TileKit"),
        .target(name: "LyricUI", dependencies: ["LyricCore", "LyricServices", "LyricPlayback", "TileKit"], path: lyricSources + "LyricUI"),
        .target(name: "NearpaneLyricsModule", dependencies: ["LyricUI", "TileKit"], path: lyricSources + "NearpaneLyricsModule"),
        .binaryTarget(name: "Sparkle", path: updateCache),
        .systemLibrary(name: "CSQLite", path: saytile + "CSQLite"),
        .target(name: "CAudio", path: saytile + "CAudio",
                exclude: ["WEBRTC-LICENSE.txt", "webrtc/common_audio/signal_processing/dot_product_with_scale.cc"],
                cSettings: [.headerSearchPath("."), .define("WEBRTC_POSIX")]),
        .target(name: "SaytileKit", dependencies: ["CSQLite", "CAudio"], path: cache + "voice-" + speech.key + voiceSuffix,
                exclude: speech.captureReadiness == nil ? [] : ["Upstream/AudioCapture.swift"],
                resources: [.copy("Upstream/Resources/ConnectionSample.pcm"), .copy("Upstream/Resources/LocalASR")]),
        .target(name: "SaytileVoiceUI", path: saytile + "SaytileVoiceUI"),
        .target(name: "RiftletCore", dependencies: ["CSQLite"], path: riftlet + "RiftletCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RiftletFeedback", dependencies: ["CSQLite"], path: riftlet + "RiftletFeedback",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RiftletCapture", dependencies: ["RiftletCore"], path: riftlet + "RiftletCapture",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RiftletAdapters", dependencies: ["RiftletCore"], path: cache + "adapters-" + tray.key + "-" + witness.compiledSHA256,
                resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RiftletUI", dependencies: ["RiftletCore", "RiftletCapture"], path: riftlet + "RiftletUI",
                exclude: ["ThumbnailCache.swift"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "NearpaneTray", dependencies: ["NearpaneCore", "RiftletCore", "RiftletCapture", "RiftletAdapters", "RiftletUI", "CSQLite"],
                path: cache + "tray-" + tray.key, sources: ["Host", "Upstream"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NearpaneTrayTests", dependencies: ["NearpaneTray", "RiftletCore", "RiftletCapture"]),
        .target(name: "NearpaneVoice", dependencies: ["NearpaneCore", "SaytileKit", "SaytileVoiceUI"]),
        .testTarget(name: "NearpaneVoiceTests", dependencies: ["NearpaneVoice", "SaytileKit", "CAudio"])
    ]
}
let package = Package(name: "Nearpane", platforms: [.macOS(full ? "26.0" : "14.0")],
                      products: [.library(name: "NearpaneCore", targets: ["NearpaneCore"]),
                                 .executable(name: "NearpaneHost", targets: ["NearpaneHost"]),
                                 .executable(name: "NearpaneSpaceAction", targets: ["NearpaneSpaceAction"]),
                                 .executable(name: "NearpaneOrdinaryWindowController", targets: ["NearpaneOrdinaryWindowController"]),
                                 .executable(name: "NearpaneDesktopReader", targets: ["NearpaneDesktopReader"])]
                         + (full ? [] : [.library(name: "NearpaneUI", targets: ["NearpaneUI"])]),
                      dependencies: full ? [.package(url: "https://github.com/jpsim/Yams.git", revision: "a27b21e0c81c5bf42049b897a62aaf387e80f279")] : [],
                      targets: targets, swiftLanguageModes: [.v6])
