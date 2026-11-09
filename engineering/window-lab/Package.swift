// swift-tools-version: 6.0
import PackageDescription

// A separate pair of acceptance processes. Neither executable is linked into the shipping Host.
let package = Package(
    name: "WindowLab", platforms: [.macOS(.v14)],
    dependencies: [.package(name: "Nearpane", path: "../..")],
    targets: [
        .target(name: "WindowLab", dependencies: [.product(name: "NearpaneCore", package: "Nearpane")]),
        .executableTarget(name: "NearpaneFixtureWindows", dependencies: ["WindowLab", .product(name: "NearpaneUI", package: "Nearpane")]),
        .executableTarget(name: "NearpaneRegularFixture", dependencies: ["WindowLab"]),
        .executableTarget(name: "NearpaneFrameController", dependencies: ["WindowLab"]),
        .testTarget(name: "FramePolicyTests", dependencies: ["NearpaneFrameController", "WindowLab"]),
    ])
