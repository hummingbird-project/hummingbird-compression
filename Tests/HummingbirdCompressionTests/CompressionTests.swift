//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CompressNIO
import Hummingbird
import HummingbirdCompression
import HummingbirdTesting
import XCTest

class HummingBirdCompressionTests: XCTestCase {
    struct Error: Swift.Error {}

    func randomBuffer(size: Int) -> ByteBuffer {
        var data = [UInt8](repeating: 0, count: size)
        data = data.map { _ in UInt8.random(in: 0...255) }
        return ByteBufferAllocator().buffer(bytes: data)
    }

    func testCompressResponse() async throws {
        let router = Router()
        router.middlewares.add(ResponseCompressionMiddleware())
        router.post("/echo") { request, _ -> Response in
            return .init(status: .ok, headers: [:], body: .init(asyncSequence: request.body))
        }
        let app = Application(router: router)
        try await app.test(.router) { client in
            let testBuffer = self.randomBuffer(size: Int.random(in: 64000...261_335))
            try await client.execute(uri: "/echo", method: .post, headers: [.acceptEncoding: "gzip"], body: testBuffer) { response in
                var body = response.body
                let uncompressed = try body.decompress(with: .gzip())
                XCTAssertEqual(uncompressed, testBuffer)
            }
        }
    }

    func testCompressDoubleResponse() async throws {
        let router = Router()
        router.middlewares.add(ResponseCompressionMiddleware())
        router.post("/echo") { request, _ -> Response in
            return .init(status: .ok, headers: [:], body: .init(asyncSequence: request.body))
        }
        let app = Application(router: router)
        let buffer = self.randomBuffer(size: 512_000)
        try await app.test(.router) { client in
            let testBuffer = buffer.getSlice(at: Int.random(in: 0...256_000), length: Int.random(in: 0...256_000))
            try await client.execute(uri: "/echo", method: .post, headers: [.acceptEncoding: "gzip"], body: testBuffer) { response in
                var body = response.body
                let uncompressed = try body.decompress(with: .gzip())
                XCTAssertEqual(uncompressed, testBuffer)
            }
            let testBuffer2 = buffer.getSlice(at: Int.random(in: 0...256_000), length: Int.random(in: 0...256_000))
            try await client.execute(uri: "/echo", method: .post, headers: [.acceptEncoding: "gzip"], body: testBuffer2) { response in
                var body = response.body
                let uncompressed = try body.decompress(with: .gzip())
                XCTAssertEqual(uncompressed, testBuffer2)
            }
        }
    }

    func testMultipleCompressResponse() async throws {
        let router = Router()
        router.middlewares.add(ResponseCompressionMiddleware())
        router.post("/echo") { request, _ -> Response in
            let body = try await request.body.collect(upTo: .max)
            return .init(status: .ok, headers: [:], body: .init(byteBuffer: body))
        }
        let app = Application(router: router)
        let buffer = self.randomBuffer(size: 512_000)
        try await app.test(.router) { client in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<32 {
                    if Bool.random() == true {
                        group.addTask {
                            try await app.test(.router) { client in
                                let testBuffer = buffer.getSlice(at: Int.random(in: 0...256_000), length: Int.random(in: 0...256_000))
                                try await client.execute(uri: "/echo", method: .post, headers: [.acceptEncoding: "gzip"], body: testBuffer) { response in
                                    var body = response.body
                                    let uncompressed = try body.decompress(with: .gzip())
                                    XCTAssertEqual(uncompressed, testBuffer)
                                }
                            }
                        }
                    } else {
                        group.addTask {
                            try await app.test(.router) { client in
                                let testBuffer = buffer.getSlice(at: Int.random(in: 0...256_000), length: Int.random(in: 0...256_000))
                                try await client.execute(uri: "/echo", method: .post, body: testBuffer) { response in
                                    XCTAssertEqual(response.body, testBuffer)
                                }
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    func testDecompressRequest() async throws {
        let router = Router()
        router.middlewares.add(HBRequestDecompressionMiddleware())
        router.post("/echo") { request, _ -> Response in
            let body = try await request.body.collect(upTo: .max)
            return .init(status: .ok, headers: [:], body: .init(byteBuffer: body))
        }
        let app = Application(router: router)
        try await app.test(.router) { client in
            let testBuffer = self.randomBuffer(size: 261_335)
            var testBufferCopy = testBuffer
            let compressedBuffer = try testBufferCopy.compress(with: .gzip())
            try await client.execute(uri: "/echo", method: .post, headers: [.contentEncoding: "gzip"], body: compressedBuffer) { response in
                XCTAssertEqual(response.body, testBuffer)
            }
        }
    }

    func testDecompressRequestStream() async throws {
        let router = Router()
        router.middlewares.add(HBRequestDecompressionMiddleware())
        router.post("/echo") { request, _ -> Response in
            return .init(status: .ok, headers: [:], body: .init(asyncSequence: request.body))
        }
        let app = Application(router: router)
        try await app.test(.router) { client in
            let testBuffer = self.randomBuffer(size: 245_355)
            var testBufferCopy = testBuffer
            let compressedBuffer = try testBufferCopy.compress(with: .gzip())
            try await client.execute(uri: "/echo", method: .post, headers: [.contentEncoding: "gzip"], body: compressedBuffer) { response in
                XCTAssertEqual(response.body, testBuffer)
            }
        }
    }

    func testDoubleDecompressRequests() async throws {
        @Sendable func compress(_ buffer: ByteBuffer) throws -> ByteBuffer {
            var b = buffer
            return try b.compress(with: .gzip())
        }
        let router = Router()
        router.middlewares.add(HBRequestDecompressionMiddleware())
        router.post("/echo") { request, _ -> Response in
            let body = try await request.body.collect(upTo: .max)
            return .init(status: .ok, headers: [:], body: .init(byteBuffer: body))
        }
        let app = Application(router: router)
        try await app.test(.router) { client in
            let buffer1 = self.randomBuffer(size: 256_000)
            let buffer2 = self.randomBuffer(size: 256_000)
            let compressedBuffer1 = try compress(buffer1)
            let compressedBuffer2 = try compress(buffer2)
            try await client.execute(uri: "/echo", method: .post, headers: [.contentEncoding: "gzip"], body: compressedBuffer1) { response in
                XCTAssertEqual(response.body, buffer1)
            }
            try await client.execute(uri: "/echo", method: .post, headers: [.contentEncoding: "gzip"], body: compressedBuffer2) { response in
                XCTAssertEqual(response.body, buffer2)
            }
        }
    }

    func testMultipleDecompressRequests() async throws {
        @Sendable func compress(_ buffer: ByteBuffer) throws -> ByteBuffer {
            var b = buffer
            return try b.compress(with: .gzip())
        }
        let router = Router()
        router.middlewares.add(HBRequestDecompressionMiddleware())
        router.post("/echo") { request, _ -> Response in
            let body = try await request.body.collect(upTo: .max)
            return .init(status: .ok, headers: [:], body: .init(byteBuffer: body))
        }
        let app = Application(router: router)
        let buffer = self.randomBuffer(size: 512_000)
        try await app.test(.router) { client in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        let testBuffer = buffer.getSlice(at: Int.random(in: 0...256_000), length: Int.random(in: 0...256_000))!
                        let compressedBuffer = try compress(testBuffer)
                        try await client.execute(uri: "/echo", method: .post, headers: [.contentEncoding: "gzip"], body: compressedBuffer) { response in
                            XCTAssertEqual(response.body, testBuffer)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    func testNoCompression() async throws {
        let router = Router()
        router.middlewares.add(HBRequestDecompressionMiddleware())
        router.post("/echo") { request, _ -> Response in
            let body = try await request.body.collect(upTo: .max)
            return .init(status: .ok, headers: [:], body: .init(byteBuffer: body))
        }
        let app = Application(router: router)
        try await app.test(.router) { client in
            let testBuffer = self.randomBuffer(size: 261_335)
            try await client.execute(uri: "/echo", method: .post, body: testBuffer) { response in
                XCTAssertEqual(response.body, testBuffer)
            }
        }
    }
}
