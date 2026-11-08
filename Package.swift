// swift-tools-version: 6.0
import PackageDescription

// scripts/test.sh and build-app.sh resolve only the pinned library inputs in this checkout's cache.
let full = Context.environment["NEARPANE_FOUNDATION_ONLY"] != "1"
let saytile = ".build/domain-inputs/2bd114f526013e6ccb422a26e17f4514e9d63836/Sources/"
let voice: [Target.Dependency] = full ? ["NearpaneVoice"] : []
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
        .target(name: "NearpaneVoice", dependencies: ["NearpaneCore", "SaytileKit"]),
        .testTarget(name: "NearpaneVoiceTests", dependencies: ["NearpaneVoice", "SaytileKit"])
    ]
}
let package = Package(name: "Nearpane", platforms: [.macOS(full ? "26.0" : "14.0")],
                      products: [.library(name: "NearpaneCore", targets: ["NearpaneCore"]),
                                 .executable(name: "NearpaneHost", targets: ["NearpaneHost"])],
                      targets: targets, swiftLanguageModes: [.v6])
