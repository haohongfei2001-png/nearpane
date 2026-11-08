// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "P1SpacesBehaviorPreparation",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "spaces-observer", targets: ["SpacesObserver"])],
    targets: [
        .target(name: "ObservationCore"),
        .executableTarget(name: "SpacesObserver", dependencies: ["ObservationCore"]),
        .testTarget(name: "ObservationCoreTests", dependencies: ["ObservationCore"])
    ],
    swiftLanguageModes: [.v5]
)
