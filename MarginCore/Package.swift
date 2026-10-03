// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarginCore",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MarginCore", targets: ["MarginCore"])
    ],
    targets: [
        .target(name: "MarginCore"),
        .testTarget(name: "MarginCoreTests", dependencies: ["MarginCore"])
    ]
)
