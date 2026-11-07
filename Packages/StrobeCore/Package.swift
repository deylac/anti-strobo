// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StrobeCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StrobeCore", targets: ["StrobeCore"]),
        .executable(name: "strobe-tune", targets: ["strobe-tune"]),
    ],
    targets: [
        .target(name: "StrobeCore"),
        .executableTarget(
            name: "strobe-tune",
            dependencies: ["StrobeCore"]
        ),
        .testTarget(
            name: "StrobeCoreTests",
            dependencies: ["StrobeCore"]
        ),
    ]
)
