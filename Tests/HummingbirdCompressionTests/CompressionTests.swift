import CompressNIO
import Hummingbird
@testable import HummingbirdCompression
import HummingbirdXCT
import XCTest

class HummingBirdCompressionTests: XCTestCase {
    struct Error: Swift.Error {}

    func randomBuffer(size: Int) -> ByteBuffer {
        var data = [UInt8](repeating: 0, count: size)
        data = data.map { _ in UInt8.random(in: 0...255) }
        return ByteBufferAllocator().buffer(bytes: data)
    }

    func testCompressResponse() {
        let app = HBApplication(testing: .embedded)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addResponseCompression()
        app.XCTStart()
        defer { app.XCTStop() }

        let testBuffer = self.randomBuffer(size: 261_335)
        app.XCTExecute(uri: "/echo", method: .GET, headers: ["accept-encoding": "gzip"], body: testBuffer) { response in
            var body = response.body
            let uncompressed = try body?.decompress(with: .gzip)
            XCTAssertEqual(uncompressed, testBuffer)
        }
    }

    func testDecompressRequest() throws {
        let app = HBApplication(testing: .embedded)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(limit: .none)
        app.XCTStart()
        defer { app.XCTStop() }

        let testBuffer = self.randomBuffer(size: 261_335)
        var testBufferCopy = testBuffer
        let compressedBuffer = try testBufferCopy.compress(with: .gzip)
        app.XCTExecute(uri: "/echo", method: .GET, headers: ["content-encoding": "gzip"], body: compressedBuffer) { response in
            XCTAssertEqual(response.body, testBuffer)
        }
    }

    func testNoCompression() throws {
        let app = HBApplication(testing: .embedded)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(limit: .none)
        app.XCTStart()
        defer { app.XCTStop() }

        let testBuffer = self.randomBuffer(size: 261_335)
        app.XCTExecute(uri: "/echo", method: .GET, body: testBuffer) { response in
            XCTAssertEqual(response.body, testBuffer)
        }
    }

    func testDecompressSizeLimit() throws {
        let app = HBApplication(testing: .embedded)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(limit: .size(50000))
        app.XCTStart()
        defer { app.XCTStop() }

        let testBuffer = self.randomBuffer(size: 150_000)
        var testBufferCopy = testBuffer
        let compressedBuffer = try testBufferCopy.compress(with: .gzip)
        app.XCTExecute(uri: "/echo", method: .GET, headers: ["content-encoding": "gzip"], body: compressedBuffer) { response in
            XCTAssertEqual(response.status, .payloadTooLarge)
        }
    }

    func testDecompressRatioLimit() throws {
        let app = HBApplication(testing: .embedded)
        app.router.get("/echo") { request -> HBResponse in
            let body: HBResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.addRequestDecompression(limit: .ratio(3))
        app.XCTStart()
        defer { app.XCTStop() }

        // create buffer that compresses down very small
        var testBuffer = ByteBufferAllocator().buffer(capacity: 65536)
        for i in 0..<65536 {
            testBuffer.writeInteger(UInt8(i & 0xFF))
        }
        var testBufferCopy = testBuffer
        let compressedBuffer = try testBufferCopy.compress(with: .gzip)
        app.XCTExecute(uri: "/echo", method: .GET, headers: ["content-encoding": "gzip"], body: compressedBuffer) { response in
            XCTAssertEqual(response.status, .payloadTooLarge)
        }
    }
}
