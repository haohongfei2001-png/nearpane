// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The wrappers authenticate the pinned inputs before SwiftPM reads them.
let full = Context.environment["NEARPANE_FOUNDATION_ONLY"] != "1"
struct DomainPin: Decodable {
    let commit: String
    let treeSHA256: String
    var key: String { commit + "-" + treeSHA256 }
}
struct DomainLock: Decodable { let domains: [String: DomainPin] }
let domains: [Target.Dependency] = full ? ["NearpaneVoice", "NearpaneTray", "SaytileVoiceUI"] : []
let fixtureDomains: [Target.Dependency] = full ? ["SaytileKit", "RiftletCore", "RiftletCapture"] : []
var targets: [Target] = [
    .target(name: "WindowGeometryCore"),
    .target(name: "CReadOnlySpaces"),
    .target(name: "NearpaneCore", dependencies: ["WindowGeometryCore"] + (full ? ["SaytileVoiceUI"] : [])),
    .executableTarget(name: "NearpaneOrdinaryWindowController", dependencies: ["NearpaneCore", "CReadOnlySpaces"]),
    .executableTarget(name: "NearpaneDesktopReader", dependencies: ["NearpaneCore", "WindowGeometryCore", "CReadOnlySpaces"]),
    .target(name: "NearpaneUI", dependencies: ["NearpaneCore", "WindowGeometryCore"] + domains),
    .executableTarget(name: "NearpaneHost", dependencies: ["NearpaneCore", "NearpaneUI"] + (full ? ["NearpaneTray", "SaytileKit", "SaytileVoiceUI", "RiftletAdapters", "RiftletCore", "RiftletCapture"] : [])),
    .testTarget(name: "WindowGeometryCoreTests", dependencies: ["WindowGeometryCore"]),
    .testTarget(name: "NearpaneOrdinaryWindowControllerTests", dependencies: ["NearpaneOrdinaryWindowController"]),
    .testTarget(name: "NearpaneDesktopReaderTests", dependencies: ["NearpaneDesktopReader", "NearpaneCore"]),
    .testTarget(name: "NearpaneCoreTests", dependencies: ["NearpaneCore"]),
    .testTarget(name: "NearpaneUITests", dependencies: ["NearpaneUI", "NearpaneCore"] + domains + fixtureDomains)
]
if full {
    let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let lock = try JSONDecoder().decode(DomainLock.self, from: Data(contentsOf: manifest.appendingPathComponent("Dependencies/domains.lock.json")))
    guard let speech = lock.domains["saytile"], let tray = lock.domains["riftlet"],
          let surface = lock.domains["saytileVoiceUI"] else { fatalError("Incomplete domain lock") }
    let run = Context.environment["NEARPANE_RUN_ID"] ?? ""
    let cache = (run.isEmpty ? ".build" : "build/standalone." + run + "/cache") + "/domain-cache-v1/"
    let saytile = cache + speech.key + "/Sources/"
    let riftlet = cache + tray.key + "/Sources/"
    targets += [
        .systemLibrary(name: "CSQLite", path: saytile + "CSQLite"),
        .target(name: "CAudio", path: saytile + "CAudio",
                exclude: ["WEBRTC-LICENSE.txt", "webrtc/common_audio/signal_processing/dot_product_with_scale.cc"],
                cSettings: [.headerSearchPath("."), .define("WEBRTC_POSIX")]),
        .target(name: "SaytileKit", dependencies: ["CSQLite", "CAudio"], path: cache + "voice-" + speech.key,
                resources: [.copy("Upstream/Resources/ConnectionSample.pcm")]),
        .target(name: "RiftletCore", dependencies: ["CSQLite"], path: riftlet + "RiftletCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RiftletCapture", dependencies: ["RiftletCore"], path: riftlet + "RiftletCapture",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RiftletAdapters", dependencies: ["RiftletCore"], path: riftlet + "RiftletAdapters",
                resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RiftletUI", dependencies: ["RiftletCore"], path: riftlet + "RiftletUI",
                exclude: ["ThumbnailCache.swift"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "NearpaneTray", dependencies: ["NearpaneCore", "RiftletCore", "RiftletCapture", "RiftletAdapters", "RiftletUI", "CSQLite"],
                path: cache + "tray-" + tray.key, sources: ["Host", "Upstream"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NearpaneTrayTests", dependencies: ["NearpaneTray", "RiftletCore", "RiftletCapture"]),
        .target(name: "SaytileVoiceUI", path: cache + surface.key + "/Sources/SaytileVoiceUI"),
        .target(name: "NearpaneVoice", dependencies: ["NearpaneCore", "SaytileKit", "SaytileVoiceUI"]),
        .testTarget(name: "NearpaneVoiceTests", dependencies: ["NearpaneVoice", "SaytileKit", "CAudio", "SaytileVoiceUI"])
    ]
}
let package = Package(name: "Nearpane", platforms: [.macOS(full ? "26.0" : "14.0")],
                      products: [.library(name: "NearpaneCore", targets: ["NearpaneCore"]),
                                 .executable(name: "NearpaneHost", targets: ["NearpaneHost"]),
                                 .executable(name: "NearpaneOrdinaryWindowController", targets: ["NearpaneOrdinaryWindowController"]),
                                 .executable(name: "NearpaneDesktopReader", targets: ["NearpaneDesktopReader"])]
                         + (full ? [] : [.library(name: "NearpaneUI", targets: ["NearpaneUI"])]),
                      targets: targets, swiftLanguageModes: [.v6])
