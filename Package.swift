// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "hummingbird-compression",
    platforms: [.iOS(.v12), .tvOS(.v12)],
    products: [
        .library(name: "HummingbirdCompression", targets: ["HummingbirdCompression"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "0.11.0"),
        .package(url: "https://github.com/adam-fowler/compress-nio.git", from: "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.20.0"),
    ],
    targets: [
        .target(name: "HummingbirdCompression", dependencies: [
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "CompressNIO", package: "compress-nio"),
        ]),
        .testTarget(name: "HummingbirdCompressionTests", dependencies: [
            .byName(name: "HummingbirdCompression"),
            .product(name: "HummingbirdXCT", package: "hummingbird"),
        ]),
    ]
)
