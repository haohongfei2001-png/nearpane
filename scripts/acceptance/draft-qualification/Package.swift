// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "NearpaneDraftQualification", platforms: [.macOS(.v13)],
  targets: [
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
    .target(name: "RiftletCore", dependencies: ["CSQLite"]),
    .target(
      name: "RiftletAdapters", dependencies: ["RiftletCore"], resources: [.process("Resources")]),
    .executableTarget(
      name: "DraftQualificationDriver", dependencies: ["RiftletCore", "RiftletAdapters"],
      swiftSettings: [.define("NEARPANE_DRAFT_QUALIFICATION")]),
    .testTarget(
      name: "RiftletQualificationTests", dependencies: ["RiftletAdapters", "RiftletCore"]),
  ])
