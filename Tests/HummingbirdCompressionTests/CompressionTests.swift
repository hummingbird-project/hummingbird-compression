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
import HummingbirdCoreXCT
import HummingbirdXCT
import XCTest

class HummingBirdCompressionTests: XCTestCase {
    struct Error: Swift.Error {}

    func randomBuffer(size: Int) -> ByteBuffer {
        var data = [UInt8](repeating: 0, count: size)
        data = data.map { _ in UInt8.random(in: 0...255) }
        return ByteBufferAllocator().buffer(bytes: data)
    }

    func testCompressResponse() throws {
        let app = HBApplication(testing: .live)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addResponseCompression(execute: .onThreadPool(threshold: 32000))
        try app.XCTStart()
        defer { app.XCTStop() }

        let testBuffer = self.randomBuffer(size: Int.random(in: 64000...261_335))
        try app.XCTExecute(uri: "/echo", method: .GET, headers: ["accept-encoding": "gzip"], body: testBuffer) { response in
            var body = response.body
            let uncompressed = try body?.decompress(with: .gzip())
            XCTAssertEqual(uncompressed, testBuffer)
        }
    }

    func testCompressResponseWithoutThreadPool() throws {
        let app = HBApplication(testing: .live, configuration: .init(enableHttpPipelining: false))
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addResponseCompression(execute: .onEventLoop)
        try app.XCTStart()
        defer { app.XCTStop() }

        let testBuffer = self.randomBuffer(size: 261_335)
        try app.XCTExecute(uri: "/echo", method: .GET, headers: ["accept-encoding": "gzip"], body: testBuffer) { response in
            var body = response.body
            let uncompressed = try body?.decompress(with: .gzip())
            XCTAssertEqual(uncompressed, testBuffer)
        }
    }

    func testMultipleCompressResponse() throws {
        let app = HBApplication(testing: .live)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addResponseCompression(execute: .onThreadPool(threshold: 64000))
        app.middleware.add(HBLogRequestsMiddleware(.info))
        try app.XCTStart()
        defer { app.XCTStop() }

        let buffers = (0..<32).map { _ in self.randomBuffer(size: Int.random(in: 16...256_000)) }
        let futures: [EventLoopFuture<Void>] = buffers.map { buffer in
            if Bool.random() == true {
                return app.xct.execute(uri: "/echo", method: .GET, headers: ["accept-encoding": "gzip"], body: buffer).flatMapThrowing { response in
                    var body = try XCTUnwrap(response.body)
                    let uncompressed = try body.decompress(with: .gzip())
                    XCTAssertEqual(uncompressed, buffer)
                }
            } else {
                return app.xct.execute(uri: "/echo", method: .GET, headers: [:], body: buffer).map { response in
                    XCTAssertEqual(response.body, buffer)
                }
            }
        }
        XCTAssertNoThrow(try EventLoopFuture.whenAllComplete(futures, on: app.eventLoopGroup.next()).wait())
    }

    func testMultipleCompressResponseWithoutThreadPool() throws {
        let app = HBApplication(testing: .live, configuration: .init(enableHttpPipelining: false))
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addResponseCompression(execute: .onEventLoop)
        try app.XCTStart()
        defer { app.XCTStop() }

        let buffers = (0..<32).map { _ in self.randomBuffer(size: Int.random(in: 16...512_000)) }
        let futures: [EventLoopFuture<Void>] = buffers.map { buffer in
            if Bool.random() == true {
                return app.xct.execute(uri: "/echo", method: .GET, headers: ["accept-encoding": "gzip"], body: buffer).flatMapThrowing { response in
                    var body = try XCTUnwrap(response.body)
                    let uncompressed = try body.decompress(with: .gzip())
                    XCTAssertEqual(uncompressed, buffer)
                }
            } else {
                return app.xct.execute(uri: "/echo", method: .GET, headers: [:], body: buffer).map { response in
                    XCTAssertEqual(response.body, buffer)
                }
            }
        }
        XCTAssertNoThrow(try EventLoopFuture.whenAllComplete(futures, on: app.eventLoopGroup.next()).wait())
    }

    func testDecompressRequest() throws {
        let app = HBApplication(testing: .live)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(execute: .onThreadPool, limit: .none)
        try app.XCTStart()
        defer { app.XCTStop() }

        let testBuffer = self.randomBuffer(size: 261_335)
        var testBufferCopy = testBuffer
        let compressedBuffer = try testBufferCopy.compress(with: .gzip())
        try app.XCTExecute(uri: "/echo", method: .GET, headers: ["content-encoding": "gzip"], body: compressedBuffer) { response in
            XCTAssertEqual(response.body, testBuffer)
        }
    }

    func testDecompressRequestWithoutThreadPool() throws {
        let app = HBApplication(testing: .live)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(execute: .onEventLoop, limit: .none)
        try app.XCTStart()
        defer { app.XCTStop() }

        let testBuffer = self.randomBuffer(size: 261_335)
        var testBufferCopy = testBuffer
        let compressedBuffer = try testBufferCopy.compress(with: .gzip())
        try app.XCTExecute(uri: "/echo", method: .GET, headers: ["content-encoding": "gzip"], body: compressedBuffer) { response in
            XCTAssertEqual(response.body, testBuffer)
        }
    }

    func testDoubleDecompressRequests() throws {
        let app = HBApplication(testing: .live)
        app.router.post("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(execute: .onThreadPool, limit: .none)
        try app.XCTStart()
        defer { app.XCTStop() }

        let client = HBXCTClient(
            host: "localhost",
            port: app.server.port!,
            configuration: .init(timeout: .seconds(60)),
            eventLoopGroupProvider: .createNew
        )
        client.connect()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        func compress(_ buffer: ByteBuffer) throws -> ByteBuffer {
            var b = buffer
            return try b.compress(with: .gzip())
        }
        let buffer1 = self.randomBuffer(size: 256_000)
        let buffer2 = self.randomBuffer(size: 256_000)
        let compressedBuffer1 = try compress(buffer1)
        let compressedBuffer2 = try compress(buffer2)
        let future1 = client.post("/echo", headers: ["content-encoding": "gzip"], body: compressedBuffer1).map { response in
            XCTAssertEqual(response.body, buffer1)
        }
        let future2 = client.post("/echo", headers: ["content-encoding": "gzip"], body: compressedBuffer2).map { response in
            XCTAssertEqual(response.body, buffer2)
        }
        XCTAssertNoThrow(try future1.and(future2).wait())
    }

    func testMultipleDecompressRequests() throws {
        let app = HBApplication(testing: .live)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(execute: .onThreadPool, limit: .none)
        try app.XCTStart()
        defer { app.XCTStop() }

        let buffers = (0..<32).map { _ in self.randomBuffer(size: Int.random(in: 16...512_000)) }
        let compressedBuffers = try buffers.map { b -> (ByteBuffer, ByteBuffer) in var b = b; return try (b, b.compress(with: .gzip())) }
        let futures: [EventLoopFuture<Void>] = compressedBuffers.map { buffers in
            if Bool.random() == true {
                return app.xct.execute(uri: "/echo", method: .GET, headers: ["content-encoding": "gzip"], body: buffers.1).map { response in
                    XCTAssertEqual(response.body, buffers.0)
                }
            } else {
                return app.xct.execute(uri: "/echo", method: .GET, headers: [:], body: buffers.0).map { response in
                    XCTAssertEqual(response.body, buffers.0)
                }
            }
        }
        XCTAssertNoThrow(try EventLoopFuture.whenAllComplete(futures, on: app.eventLoopGroup.next()).wait())
    }

    func testMultipleDecompressRequestsWithoutThreadPool() throws {
        let app = HBApplication(testing: .live, configuration: .init(enableHttpPipelining: false))
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(execute: .onEventLoop, limit: .none)
        try app.XCTStart()
        defer { app.XCTStop() }

        let buffers = (0..<32).map { _ in self.randomBuffer(size: Int.random(in: 16...512_000)) }
        let compressedBuffers = try buffers.map { b -> (ByteBuffer, ByteBuffer) in var b = b; return try (b, b.compress(with: .gzip())) }
        let futures: [EventLoopFuture<Void>] = compressedBuffers.map { buffers in
            if Bool.random() == true {
                return app.xct.execute(uri: "/echo", method: .GET, headers: ["content-encoding": "gzip"], body: buffers.1).map { response in
                    XCTAssertEqual(response.body, buffers.0)
                }
            } else {
                return app.xct.execute(uri: "/echo", method: .GET, headers: [:], body: buffers.0).map { response in
                    XCTAssertEqual(response.body, buffers.0)
                }
            }
        }
        XCTAssertNoThrow(try EventLoopFuture.whenAllComplete(futures, on: app.eventLoopGroup.next()).wait())
    }

    func testNoCompression() throws {
        let app = HBApplication(testing: .live)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(execute: .onThreadPool, limit: .none)
        try app.XCTStart()
        defer { app.XCTStop() }

        let testBuffer = self.randomBuffer(size: 261_335)
        try app.XCTExecute(uri: "/echo", method: .GET, body: testBuffer) { response in
            XCTAssertEqual(response.body, testBuffer)
        }
    }

    func testDecompressSizeLimit() throws {
        let app = HBApplication(testing: .live)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(execute: .onThreadPool, limit: .size(50000))
        try app.XCTStart()
        defer { app.XCTStop() }

        let testBuffer = self.randomBuffer(size: 150_000)
        var testBufferCopy = testBuffer
        let compressedBuffer = try testBufferCopy.compress(with: .gzip())
        try app.XCTExecute(uri: "/echo", method: .GET, headers: ["content-encoding": "gzip"], body: compressedBuffer) { response in
            XCTAssertEqual(response.status, .payloadTooLarge)
        }
    }

    func testDecompressRatioLimit() throws {
        let app = HBApplication(testing: .live)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(execute: .onThreadPool, limit: .ratio(3))
        try app.XCTStart()
        defer { app.XCTStop() }

        // create buffer that compresses down very small
        var testBuffer = ByteBufferAllocator().buffer(capacity: 65536)
        for i in 0..<65536 {
            testBuffer.writeInteger(UInt8(i & 0xFF))
        }
        var testBufferCopy = testBuffer
        let compressedBuffer = try testBufferCopy.compress(with: .gzip())
        try app.XCTExecute(uri: "/echo", method: .GET, headers: ["content-encoding": "gzip"], body: compressedBuffer) { response in
            XCTAssertEqual(response.status, .payloadTooLarge)
        }
    }
}
