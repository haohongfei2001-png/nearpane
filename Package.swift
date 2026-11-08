// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nearpane",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NearpaneCore", targets: ["NearpaneCore"]),
        .executable(name: "NearpaneHost", targets: ["NearpaneHost"])
    ],
    targets: [
        .target(name: "NearpaneCore"),
        .target(name: "NearpaneUI", dependencies: ["NearpaneCore"]),
        .executableTarget(name: "NearpaneHost", dependencies: ["NearpaneCore", "NearpaneUI"]),
        .testTarget(name: "NearpaneCoreTests", dependencies: ["NearpaneCore"]),
        .testTarget(name: "NearpaneUITests", dependencies: ["NearpaneUI", "NearpaneCore"])
    ],
    swiftLanguageModes: [.v6]
)
