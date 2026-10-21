// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexNotchMeter",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NotchCore", targets: ["NotchCore"]),
        .executable(name: "CodexNotchMeter", targets: ["CodexNotchMeter"])
    ],
    targets: [
        .target(name: "NotchCore"),
        .executableTarget(name: "CodexNotchMeter", dependencies: ["NotchCore"],
                          swiftSettings: [.define("AMLL_FALLBACK")]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"])
    ]
)
