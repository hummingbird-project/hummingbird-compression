import CompressNIO
import NIO
import NIOHTTP1

class HTTPRequestDecompressHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart

    enum State {
        case decompressingBody(NIODecompressor)
        case receivingBody
        case idle
    }

    let decompressorWindow: ByteBuffer
    var state: State

    init(windowSize: Int = 32*1024) {
        self.state = .idle
        self.decompressorWindow = ByteBufferAllocator().buffer(capacity: windowSize)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch (part, self.state) {
        case (.head(let head), .idle):
            if let decompressor = self.decompressor(from: head.headers[canonicalForm: "content-encoding"]) {
                decompressor.window = self.decompressorWindow
                try! decompressor.startStream()
                self.state = .decompressingBody(decompressor)
            } else {
                self.state = .receivingBody
            }
            context.fireChannelRead(self.wrapInboundOut(.head(head)))

        case (.body(let part), .decompressingBody(let decompressor)):
            writeBuffer(context: context, buffer: part, decompressor: decompressor, promise: nil)

        case (.body, .receivingBody):
            context.fireChannelRead(data)

        case (.end, .decompressingBody(let decompressor)):
            try! decompressor.finishStream()
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

    private func writeBuffer(context: ChannelHandlerContext, buffer: ByteBuffer, decompressor: NIODecompressor, promise: EventLoopPromise<Void>?) {
        var buffer = buffer
        do {
            try buffer.decompressStream(with: decompressor) { buffer in
                context.fireChannelRead(self.wrapInboundOut(.body(buffer)))
            }
        } catch {
            promise?.fail(error)
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
