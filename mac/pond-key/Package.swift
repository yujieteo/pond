// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pond-key",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../PondKit")],
    targets: [
        .target(name: "PondKey", dependencies: ["PondKit"]),
        .executableTarget(name: "pond-key", dependencies: ["PondKey"]),
        .testTarget(name: "PondKeyTests", dependencies: ["PondKey"]),
    ]
)
