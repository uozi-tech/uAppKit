// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "UDesignKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "UDesignKit", targets: ["UDesignKit"]),
    ],
    targets: [
        .target(name: "UDesignKit"),
    ]
)
