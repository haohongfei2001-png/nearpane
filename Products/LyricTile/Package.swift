// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LyricTile",
    platforms: [.macOS(.v14)], // Reusable source floor; distribution qualification is macOS 27.
    products: [
        .executable(name: "LyricTile", targets: ["LyricTileApp"]),
        .library(name: "LyricCore", targets: ["LyricCore"]),
        .library(name: "LyricServices", targets: ["LyricServices"]),
        .library(name: "LyricPlayback", targets: ["LyricPlayback"]),
        .library(name: "LyricUI", targets: ["LyricUI"]),
        .library(name: "TileKit", targets: ["TileKit"]),
        .library(name: "NearpaneLyricsModule", targets: ["NearpaneLyricsModule"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")
    ],
    targets: [
        .target(name: "LyricCore"),
        .target(name: "LyricServices", dependencies: ["LyricCore", .product(name: "Yams", package: "Yams")]),
        .target(name: "CPlayerBridge", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("AppKit"), .linkedFramework("ScriptingBridge")]),
        .target(name: "LyricPlayback", dependencies: ["LyricCore", "CPlayerBridge"]),
        .target(name: "CTileLock", publicHeadersPath: "include"),
        .target(name: "TileKit", dependencies: ["CTileLock"]),
        .target(name: "LyricUI", dependencies: ["LyricCore", "LyricServices", "LyricPlayback", "TileKit"]),
        .target(name: "NearpaneLyricsModule", dependencies: ["LyricUI", "TileKit"]),
        .executableTarget(name: "LyricTileApp", dependencies: ["LyricUI", "LyricPlayback", "TileKit", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "LyricCoreTests", dependencies: ["LyricCore"]),
        .testTarget(name: "LyricServicesTests", dependencies: ["LyricCore", "LyricServices"]),
        .testTarget(name: "LyricPlaybackTests", dependencies: ["LyricCore", "LyricPlayback"]),
        .testTarget(name: "LyricUITests", dependencies: ["LyricUI"]),
        .testTarget(name: "TileKitTests", dependencies: ["TileKit"])
    ]
)
