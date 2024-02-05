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
/*
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
        case decompressingBody(DecompressionState)
        case finishingDecompress
        case receivingBody
        case idle

        class DecompressionState {
            init(decompressor: NIODecompressor, limit: HTTPDecompressionLimit) {
                self.decompressor = decompressor
                self.limit = limit
                self.futureResult = nil
                self.compressedSizeRead = 0
                self.decompressedSizeWritten = 0
                self.exceededLimit = false
            }

            let decompressor: NIODecompressor
            let limit: HTTPDecompressionLimit
            var futureResult: EventLoopFuture<Void>?
            var compressedSizeRead: Int
            var decompressedSizeWritten: Int
            var exceededLimit: Bool

            func writeBuffer(buffer: ByteBuffer, _ writeBuffer: (ByteBuffer) -> Void) throws {
                // if last write exceeded decompress limit then skip decompression
                guard self.exceededLimit == false else { return }
                var buffer = buffer
                do {
                    self.compressedSizeRead += buffer.readableBytes
                    try buffer.decompressStream(with: self.decompressor) { buffer in
                        self.decompressedSizeWritten += buffer.readableBytes
                        writeBuffer(buffer)
                    }
                } catch {
                    throw HBHTTPError(.badRequest)
                }
                // if exceeeded
                if self.limit.hasExceeded(compressed: self.compressedSizeRead, decompressed: self.decompressedSizeWritten) {
                    self.exceededLimit = true
                    throw HBHTTPError(.payloadTooLarge)
                }
            }

            func finish() throws {
                try self.decompressor.finishStream()
            }
        }
    }

    var state: State
    let limit: HTTPDecompressionLimit
    let threadPool: NIOThreadPool?
    let decompressorWindow: ByteBuffer
    var queue: TaskQueue<Void>!

    init(limit: HTTPDecompressionLimit, threadPool: NIOThreadPool?, windowSize: Int = 32 * 1024) {
        self.state = .idle
        self.limit = limit
        self.threadPool = threadPool
        self.decompressorWindow = ByteBufferAllocator().buffer(capacity: windowSize)
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
                decompressor.window = self.decompressorWindow
                do {
                    try decompressor.startStream()
                } catch {
                    context.fireErrorCaught(HBHTTPError(.internalServerError))
                }
                self.state = .decompressingBody(.init(decompressor: decompressor, limit: self.limit))
            } else {
                self.state = .receivingBody
            }
            context.fireChannelRead(self.wrapInboundOut(.head(head)))

        case (.body(let part), .decompressingBody(let decompressionState)):
            if let threadPool = threadPool {
                decompressionState.futureResult = self.queue.submitTask {
                    threadPool.runIfActive(eventLoop: context.eventLoop) {
                        do {
                            try decompressionState.writeBuffer(buffer: part) { buffer in
                                context.eventLoop.execute {
                                    context.fireChannelRead(self.wrapInboundOut(.body(buffer)))
                                }
                            }
                        } catch {
                            context.eventLoop.execute {
                                context.fireErrorCaught(error)
                            }
                        }
                    }
                }
            } else {
                do {
                    try decompressionState.writeBuffer(buffer: part) { buffer in
                        context.fireChannelRead(self.wrapInboundOut(.body(buffer)))
                    }
                } catch {
                    context.fireErrorCaught(error)
                }
            }

        case (.body, .receivingBody):
            context.fireChannelRead(data)

        case (.end, .decompressingBody(let decompressionState)):
            if let future = decompressionState.futureResult {
                self.state = .finishingDecompress
                // wait until last body part has been passed on
                future.whenComplete { _ in
                    self.state = .idle
                    do {
                        try decompressionState.finish()
                    } catch {
                        context.fireErrorCaught(HBHTTPError(.internalServerError))
                    }
                    context.fireChannelRead(data)
                }
            } else {
                self.state = .idle
                do {
                    try decompressionState.finish()
                } catch {
                    context.fireErrorCaught(HBHTTPError(.internalServerError))
                }
                context.fireChannelRead(data)
            }

        case (.end, .receivingBody):
            self.state = .idle
            context.fireChannelRead(data)

        default:
            assertionFailure("Shouldn't get here")
            context.close(promise: nil)
        }
    }

    /// Determines the decompression algorithm based off content encoding header.
    private func decompressor(from contentEncodingHeaders: [Substring]) -> NIODecompressor? {
        for encoding in contentEncodingHeaders {
            switch encoding {
            case "gzip":
                return CompressionAlgorithm.gzip().decompressor
            case "deflate":
                return CompressionAlgorithm.zlib().decompressor
            default:
                break
            }
        }
        return nil
    }
}
*/