// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NearpaneWindowGeometryPreparation",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WindowGeometryCore", targets: ["WindowGeometryCore"]),
        .library(name: "ReadOnlyWindowMetadata", targets: ["ReadOnlyWindowMetadata"]),
    ],
    targets: [
        .target(name: "WindowGeometryCore"),
        .target(name: "ReadOnlyWindowMetadata", dependencies: ["WindowGeometryCore"]),
        .testTarget(name: "WindowGeometryCoreTests", dependencies: ["WindowGeometryCore"]),
    ]
)
