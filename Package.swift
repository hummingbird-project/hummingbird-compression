// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "hummingbird-compression",
    products: [
        .library(name: "HummingBirdCompression", targets: ["HummingBirdCompression"]),
    ],
    dependencies: [
        .package(url: "https://github.com/adam-fowler/hummingbird.git", .branch("main")),
        .package(url: "https://github.com/adam-fowler/compress-nio.git", from: "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.20.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.2.0"),
    ],
    targets: [
        .target(name: "HummingBirdCompression", dependencies: [
            .product(name: "HummingBird", package: "hummingbird"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "CompressNIO", package: "compress-nio"),
        ]),
        .testTarget(name: "HummingBirdCompressionTests", dependencies: [
            .byName(name: "HummingBirdCompression"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
        ]),
    ]
)
