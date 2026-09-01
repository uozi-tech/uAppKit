// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "UAppKitBridge",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "UAppKitBridge", targets: ["UAppKitBridge"]),
    ],
    targets: [
        .target(name: "UAppKitBridge"),
        .testTarget(name: "UAppKitBridgeTests", dependencies: ["UAppKitBridge"]),
    ]
)
