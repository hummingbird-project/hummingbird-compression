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
        switch limit {
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
        case decompressingBody(NIODecompressor)
        case receivingBody
        case idle
    }

    var state: State
    let limit: HTTPDecompressionLimit
    let decompressorWindow: ByteBuffer
    var compressedSize: Int
    var decompressedSize: Int

    init(limit: HTTPDecompressionLimit, windowSize: Int = 32*1024) {
        self.state = .idle
        self.limit = limit
        self.decompressorWindow = ByteBufferAllocator().buffer(capacity: windowSize)
        self.compressedSize = 0
        self.decompressedSize = 0
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
                    context.fireErrorCaught(HTTPError(.internalServerError))
                }
                self.state = .decompressingBody(decompressor)
            } else {
                self.state = .receivingBody
            }
            context.fireChannelRead(self.wrapInboundOut(.head(head)))

        case (.body(let part), .decompressingBody(let decompressor)):
            writeBuffer(context: context, buffer: part, decompressor: decompressor)

        case (.body, .receivingBody):
            context.fireChannelRead(data)

        case (.end, .decompressingBody(let decompressor)):
            do {
                try decompressor.finishStream()
            } catch {
                context.fireErrorCaught(HTTPError(.internalServerError))
            }
            context.fireChannelRead(data)
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
                context.fireChannelRead(self.wrapInboundOut(.body(buffer)))
            }
            if self.limit.hasExceeded(compressed: self.compressedSize, decompressed: self.decompressedSize) {
                context.fireErrorCaught(HTTPError(.payloadTooLarge))
            }
        } catch {
            context.fireErrorCaught(HTTPError(.badRequest))
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
