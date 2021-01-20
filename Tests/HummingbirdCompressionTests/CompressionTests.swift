import AsyncHTTPClient
import Hummingbird
import HummingbirdCompression
import XCTest

class HummingBirdCompressionTests: XCTestCase {
    struct Error: Swift.Error {}

    public class VerifyBufferCompressedHandler: ChannelOutboundHandler {
        public typealias OutboundIn = HTTPServerResponsePart

        let size: Int

        init(size: Int) {
            self.size = size
        }
        public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            if case .body(let bytebuffer) = unwrapOutboundIn(data) {
                XCTAssertNotEqual(size, bytebuffer.readableBytes)
            }
            context.write(data, promise: promise)
        }
    }

    func randomBuffer(size: Int) -> ByteBuffer {
        var data = [UInt8](repeating: 0, count: size)
        data = data.map { _ in UInt8.random(in: 0...255) }
        return ByteBufferAllocator().buffer(bytes: data)
    }

    func testCompressResponse() {
        let testBuffer = randomBuffer(size: 261335)
        let app = Application()
        app.httpServer
            .addChildChannelHandler(VerifyBufferCompressedHandler(size: testBuffer.readableBytes), position: .afterHTTP)
            .addResponseCompression()
        app.router.put("/echo") { request -> Response in
            let body: ResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.start()
        defer { app.stop(); app.wait() }

        let client = HTTPClient(eventLoopGroupProvider: .shared(app.eventLoopGroup), configuration: .init(decompression: .enabled(limit: .none)))
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let response =  client.put(url: "http://localhost:\(app.configuration.address.port!)/echo", body: .byteBuffer(testBuffer)).flatMapThrowing { response in
            XCTAssertEqual(testBuffer, response.body)
        }
        XCTAssertNoThrow(try response.wait())
    }

    func testDecompressRequest() throws {
        let testBuffer = randomBuffer(size: 261335)
        let app = Application()
        app.httpServer
            .addRequestDecompression(limit: .none)
        app.router.put("/echo") { request -> Response in
            let body: ResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.start()
        defer { app.stop(); app.wait() }

        var testBuffer2 = testBuffer
        let compressedBuffer = try testBuffer2.compress(with: .gzip)

        let client = HTTPClient(eventLoopGroupProvider: .shared(app.eventLoopGroup), configuration: .init(decompression: .enabled(limit: .none)))
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let request = try HTTPClient.Request(
            url: "http://localhost:\(app.configuration.address.port!)/echo",
            method: .PUT,
            headers: ["content-encoding": "gzip"],
            body: .byteBuffer(compressedBuffer)
        )
        let response =  client.execute(request: request).flatMapThrowing { response in
            XCTAssertEqual(testBuffer, response.body)
        }
        XCTAssertNoThrow(try response.wait())
    }

    func testNoCompression() throws {
        let testBuffer = randomBuffer(size: 261335)
        let app = Application()
        app.httpServer
            .addRequestDecompression(limit: .none)
            .addResponseCompression()
        app.router.put("/echo") { request -> Response in
            let body: ResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.start()
        defer { app.stop(); app.wait() }

        let client = HTTPClient(eventLoopGroupProvider: .shared(app.eventLoopGroup))
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let request = try HTTPClient.Request(
            url: "http://localhost:\(app.configuration.address.port!)/echo",
            method: .PUT,
            headers: [:],
            body: .byteBuffer(testBuffer)
        )
        let response =  client.execute(request: request).flatMapThrowing { response in
            XCTAssertEqual(testBuffer, response.body)
        }
        XCTAssertNoThrow(try response.wait())
    }

    func testDecompressSizeLimit() throws {
        let testBuffer = randomBuffer(size: 150000)
        let app = Application()
        app.httpServer
            .addRequestDecompression(limit: .size(50000))
            .addResponseCompression()
        app.router.put("/echo") { request -> Response in
            let body: ResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.start()
        defer { app.stop(); app.wait() }

        var testBuffer2 = testBuffer
        let compressedBuffer = try testBuffer2.compress(with: .gzip)

        let client = HTTPClient(eventLoopGroupProvider: .shared(app.eventLoopGroup))
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let request = try HTTPClient.Request(
            url: "http://localhost:\(app.configuration.address.port!)/echo",
            method: .PUT,
            headers: ["content-encoding": "gzip"],
            body: .byteBuffer(compressedBuffer)
        )
        let response =  client.execute(request: request).flatMapThrowing { response in
            XCTAssertEqual(response.status, .payloadTooLarge)
        }
        XCTAssertNoThrow(try response.wait())

    }

    func testDecompressRatioLimit() throws {
        // create buffer that compresses down very small
        var testBuffer = ByteBufferAllocator().buffer(capacity: 65536)
        for i in 0..<65536 {
            testBuffer.writeInteger(UInt8(i & 0xff))
        }

        let app = Application()
        app.httpServer
            .addRequestDecompression(limit: .ratio(3))
            .addResponseCompression()
        app.router.put("/echo") { request -> Response in
            let body: ResponseBody = request.body.buffer.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.start()
        defer { app.stop(); app.wait() }

        var testBuffer2 = testBuffer
        let compressedBuffer = try testBuffer2.compress(with: .gzip)

        let client = HTTPClient(eventLoopGroupProvider: .shared(app.eventLoopGroup))
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let request = try HTTPClient.Request(
            url: "http://localhost:\(app.configuration.address.port!)/echo",
            method: .PUT,
            headers: ["content-encoding": "gzip"],
            body: .byteBuffer(compressedBuffer)
        )
        let response =  client.execute(request: request).flatMapThrowing { response in
            XCTAssertEqual(response.status, .payloadTooLarge)
        }
        XCTAssertNoThrow(try response.wait())

    }
}
