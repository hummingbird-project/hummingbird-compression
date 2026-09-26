// swift-tools-version:6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "hummingbird-compression",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "HummingbirdCompression", targets: ["HummingbirdCompression"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0", traits: []),
        .package(url: "https://github.com/adam-fowler/compress-nio.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.32.1"),
    ],
    targets: [
        .target(
            name: "HummingbirdCompression",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "CompressNIO", package: "compress-nio"),
            ]
        ),
        .testTarget(
            name: "HummingbirdCompressionTests",
            dependencies: [
                .byName(name: "HummingbirdCompression"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
