import CompressNIO
import Hummingbird
import NIO
import NIOHTTP1

/// Limits for when decompressing HTTP request data
public struct HTTPDecompressionLimit {
    private enum Limit {
        case none
        case size(Int)
        case ratio(Double)
    }

    private let limit: Limit
    private init(_ limit: Limit) {
        self.limit = limit
    }

    public static var none: Self { .init(.none) }
    public static func size(_ value: Int) -> Self { .init(.size(value)) }
    public static func ratio(_ value: Double) -> Self { .init(.ratio(value)) }

    func hasExceeded(compressed: Int, decompressed: Int) -> Bool {
        switch self.limit {
        case .size(let size):
            return decompressed > size
        case .ratio(let ratio):
            return Double(decompressed) / Double(compressed) > ratio
        default:
            return false
        }
    }
}

/// HTTP Request Decompression Channel Handler
class HTTPRequestDecompressHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart

    enum State {
        case decompressingBody(NIODecompressor, EventLoopFuture<Void>?)
        case receivingBody
        case idle
        
        class DecompressionState {
            init(decompressor: NIODecompressor) {
                self.decompressor = decompressor
                self.futureResult = nil
                self.compressedSizeRead = 0
                self.decompressedSizeWritten = 0
            }
            let decompressor: NIODecompressor
            let futureResult: EventLoopFuture<Void>?
            let compressedSizeRead: Int
            let decompressedSizeWritten: Int
        }
    }

    var state: State
    let limit: HTTPDecompressionLimit
    let threadPool: NIOThreadPool
    let decompressorWindow: ByteBuffer
    var compressedSize: Int
    var decompressedSize: Int
    var queue: TaskQueue<Void>!

    init(limit: HTTPDecompressionLimit, threadPool: NIOThreadPool, windowSize: Int = 32 * 1024) {
        self.state = .idle
        self.limit = limit
        self.threadPool = threadPool
        self.decompressorWindow = ByteBufferAllocator().buffer(capacity: windowSize)
        self.compressedSize = 0
        self.decompressedSize = 0
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.queue = TaskQueue(on: context.eventLoop)
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        // cancel any queued actions
        self.queue.cancelQueue()
        self.queue = nil
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch (part, self.state) {
        case (.head(let head), .idle):
            if let decompressor = self.decompressor(from: head.headers[canonicalForm: "content-encoding"]) {
                self.compressedSize = 0
                self.decompressedSize = 0
                decompressor.window = self.decompressorWindow
                do {
                    try decompressor.startStream()
                } catch {
                    context.fireErrorCaught(HBHTTPError(.internalServerError))
                }
                self.state = .decompressingBody(decompressor, nil)
            } else {
                self.state = .receivingBody
            }
            context.fireChannelRead(self.wrapInboundOut(.head(head)))

        case (.body(let part), .decompressingBody(let decompressor, _)):
            let future = queue.submitTask {
                self.threadPool.runIfActive(eventLoop: context.eventLoop) {
                    self.writeBuffer(context: context, buffer: part, decompressor: decompressor)
                }
            }
            self.state = .decompressingBody(decompressor, future)
            
        case (.body, .receivingBody):
            context.fireChannelRead(data)

        case (.end, .decompressingBody(let decompressor, let future)):
            if let future = future {
                // wait until last body part has been passed on
                future.whenComplete { _ in
                    do {
                        try decompressor.finishStream()
                    } catch {
                        context.fireErrorCaught(HBHTTPError(.internalServerError))
                    }
                    context.fireChannelRead(data)
                }
            } else {
                do {
                    try decompressor.finishStream()
                } catch {
                    context.fireErrorCaught(HBHTTPError(.internalServerError))
                }
                context.fireChannelRead(data)
            }
            self.state = .idle

        case (.end, .receivingBody):
            context.fireChannelRead(data)
            self.state = .idle

        default:
            assertionFailure("Shouldn't get here")
            context.close(promise: nil)
        }
    }

    private func writeBuffer(context: ChannelHandlerContext, buffer: ByteBuffer, decompressor: NIODecompressor) {
        var buffer = buffer
        do {
            self.compressedSize += buffer.readableBytes
            try buffer.decompressStream(with: decompressor) { buffer in
                self.decompressedSize += buffer.readableBytes
                _ = context.eventLoop.submit {
                    context.fireChannelRead(self.wrapInboundOut(.body(buffer)))
                }
            }
            if self.limit.hasExceeded(compressed: self.compressedSize, decompressed: self.decompressedSize) {
                _ = context.eventLoop.submit {
                    context.fireErrorCaught(HBHTTPError(.payloadTooLarge))
                }
            }
        } catch {
            _ = context.eventLoop.submit {
                context.fireErrorCaught(HBHTTPError(.badRequest))
            }
        }
    }

    /// Determines the decompression algorithm based off content encoding header.
    private func decompressor(from contentEncodingHeaders: [Substring]) -> NIODecompressor? {
        for encoding in contentEncodingHeaders {
            switch encoding {
            case "gzip":
                return CompressionAlgorithm.gzip.decompressor
            case "deflate":
                return CompressionAlgorithm.deflate.decompressor
            default:
                break
            }
        }
        return nil
    }
}
