// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PondKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PondKit", targets: ["PondKit"])],
    targets: [
        .target(name: "PondKit"),
        .testTarget(name: "PondKitTests", dependencies: ["PondKit"], resources: [.copy("Fixtures")]),
    ]
)
