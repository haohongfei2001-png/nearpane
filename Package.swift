// swift-tools-version: 6.0
import PackageDescription

// scripts/test.sh and build-app.sh resolve only the pinned library inputs in this checkout's cache.
let full = Context.environment["NEARPANE_FOUNDATION_ONLY"] != "1"
let saytile = ".build/domain-inputs/2bd114f526013e6ccb422a26e17f4514e9d63836/Sources/"
let riftlet = ".build/domain-inputs/5c0e3da8ae2339910321fa9211dc6c5d6d6a3a7d/Sources/"
let voice: [Target.Dependency] = full ? ["NearpaneVoice", "NearpaneTray"] : []
var targets: [Target] = [
    .target(name: "NearpaneCore"),
    .target(name: "NearpaneUI", dependencies: ["NearpaneCore"] + voice),
    .executableTarget(name: "NearpaneHost", dependencies: ["NearpaneCore", "NearpaneUI"]),
    .testTarget(name: "NearpaneCoreTests", dependencies: ["NearpaneCore"]),
    .testTarget(name: "NearpaneUITests", dependencies: ["NearpaneUI", "NearpaneCore"] + voice)
]
if full {
    targets += [
        .systemLibrary(name: "CSQLite", path: saytile + "CSQLite"),
        .target(name: "CAudio", path: saytile + "CAudio",
                exclude: ["WEBRTC-LICENSE.txt", "webrtc/common_audio/signal_processing/dot_product_with_scale.cc"],
                cSettings: [.headerSearchPath("."), .define("WEBRTC_POSIX")]),
        .target(name: "SaytileKit", dependencies: ["CSQLite", "CAudio"], path: saytile + "SaytileKit",
                resources: [.copy("Resources/ConnectionSample.pcm")]),
        .target(name: "RiftletCore", dependencies: ["CSQLite"], path: riftlet + "RiftletCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RiftletCapture", dependencies: ["RiftletCore"], path: riftlet + "RiftletCapture",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RiftletAdapters", dependencies: ["RiftletCore"], path: riftlet + "RiftletAdapters",
                resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RiftletUI", dependencies: ["RiftletCore"], path: riftlet + "RiftletUI",
                exclude: ["ThumbnailCache.swift"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "NearpaneTray", dependencies: ["NearpaneCore", "RiftletCore", "RiftletCapture", "RiftletAdapters", "RiftletUI", "CSQLite"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NearpaneTrayTests", dependencies: ["NearpaneTray", "RiftletCore", "RiftletCapture"]),
        .target(name: "NearpaneVoice", dependencies: ["NearpaneCore", "SaytileKit"]),
        .testTarget(name: "NearpaneVoiceTests", dependencies: ["NearpaneVoice", "SaytileKit"])
    ]
}
let package = Package(name: "Nearpane", platforms: [.macOS(full ? "26.0" : "14.0")],
                      products: [.library(name: "NearpaneCore", targets: ["NearpaneCore"]),
                                 .executable(name: "NearpaneHost", targets: ["NearpaneHost"])],
                      targets: targets, swiftLanguageModes: [.v6])
