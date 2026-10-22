// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DonutFill",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScanKit", targets: ["ScanKit"]),
        .executable(name: "scankit-cli", targets: ["scankit-cli"]),
        .executable(name: "DonutFill", targets: ["DonutFill"]),
    ],
    targets: [
        .target(name: "ScanKit"),
        .executableTarget(name: "scankit-cli", dependencies: ["ScanKit"]),
        .executableTarget(name: "DonutFill", dependencies: ["ScanKit"]),
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit"]),
    ]
)
