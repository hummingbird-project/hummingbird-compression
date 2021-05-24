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
import NIO
import NIOHTTP1

/// HTTP Response compression channel handler. Compresses HTTP body when accept-encoding header in Request indicates
/// the client will accept compressed data
class HTTPResponseCompressHandler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTPServerResponsePart

    enum State {
        case head(HTTPResponseHead)
        case body(NIOCompressor?)
        case idle
    }

    var acceptQueue: CircularBuffer<[Substring]>
    let compressorWindow: ByteBuffer
    var state: State
    let threadPool: NIOThreadPool?
    var pendingPromise: EventLoopPromise<Void>?
    var queue: TaskQueue<Void>!

    init(threadPool: NIOThreadPool?, windowSize: Int = 32 * 1024) {
        self.state = .idle
        self.threadPool = threadPool
        self.acceptQueue = .init(initialCapacity: 4)
        self.compressorWindow = ByteBufferAllocator().buffer(capacity: windowSize)
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
        let part = self.unwrapInboundIn(data)
        if case .head(let head) = part {
            // store accept-encoding header for when we are writing our response
            acceptQueue.append(head.headers[canonicalForm: "accept-encoding"])
        }
        context.fireChannelRead(data)
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = unwrapOutboundIn(data)

        if let promise = promise {
            if let pendingPromise = self.pendingPromise {
                pendingPromise.futureResult.cascade(to: promise)
            } else {
                self.pendingPromise = promise
            }
        }

        switch (part, self.state) {
        case (.head(let head), .idle):
            self.state = .head(head)

        case (.body(let part), .head(var head)):
            // if compression is accepted
            if let compression = self.compressionAlgorithm(from: acceptQueue.removeFirst()) {
                // start compression
                let compressor = compression.compressor
                compressor.window = self.compressorWindow
                do {
                    try compressor.startStream()

                    // edit header, removing content-length and adding content-encoding
                    head.headers.replaceOrAdd(name: "content-encoding", value: compression.name)
                    head.headers.remove(name: "content-length")
                    context.write(wrapOutboundOut(.head(head)), promise: nil)
                    if let threadPool = self.threadPool {
                        self.queue.submitTask {
                            threadPool.runIfActive(eventLoop: context.eventLoop) {
                                self.writeBuffer(context: context, part: part, compressor: compressor, promise: nil)
                            }
                        }
                    } else {
                        self.writeBuffer(context: context, part: part, compressor: compressor, promise: nil)
                    }
                    self.state = .body(compressor)
                } catch {
                    // if compressor failed to start stream then output uncompressed data
                    self.state = .body(nil)
                    context.write(wrapOutboundOut(.head(head)), promise: nil)
                    context.write(data, promise: nil)
                }
            } else {
                self.state = .body(nil)
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.write(data, promise: nil)
            }

        case (.body(let part), .body(let compressor)):
            if let compressor = compressor {
                if let threadPool = self.threadPool {
                    self.queue.submitTask {
                        threadPool.runIfActive(eventLoop: context.eventLoop) {
                            self.writeBuffer(context: context, part: part, compressor: compressor, promise: nil)
                        }
                    }
                } else {
                    self.writeBuffer(context: context, part: part, compressor: compressor, promise: nil)
                }
            } else {
                context.write(data, promise: nil)
            }

        case (.end, .head(let head)):
            self.state = .idle
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.write(data, promise: self.pendingPromise)
            self.pendingPromise = nil

        case (.end, .body(let compressor)):
            self.state = .idle
            if let compressor = compressor {
                let pendingPromise = self.pendingPromise
                if let threadPool = self.threadPool {
                    self.queue.submitTask {
                        threadPool.runIfActive(eventLoop: context.eventLoop) {
                            do {
                                self.finalizeStream(context: context, compressor: compressor, promise: nil)
                                try compressor.finishStream()
                            } catch {
                                self.pendingPromise?.fail(error)
                            }
                            context.eventLoop.execute {
                                context.writeAndFlush(data, promise: pendingPromise)
                            }
                        }
                    }
                } else {
                    do {
                        self.finalizeStream(context: context, compressor: compressor, promise: nil)
                        try compressor.finishStream()
                    } catch {
                        self.pendingPromise?.fail(error)
                    }
                    context.writeAndFlush(data, promise: pendingPromise)
                }
            } else {
                context.write(data, promise: self.pendingPromise)
            }
            self.pendingPromise = nil

        default:
            assertionFailure("Shouldn't get here")
            context.close(promise: nil)
        }
    }

    private func writeBuffer(context: ChannelHandlerContext, part: IOData, compressor: NIOCompressor, promise: EventLoopPromise<Void>?) {
        guard case .byteBuffer(var buffer) = part else { fatalError("Cannot currently compress file regions") }
        do {
            try buffer.compressStream(with: compressor, flush: .sync) { buffer in
                if context.eventLoop.inEventLoop {
                    context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                } else {
                    context.eventLoop.execute {
                        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            }
        } catch {
            promise?.fail(error)
        }
    }

    private func finalizeStream(context: ChannelHandlerContext, compressor: NIOCompressor, promise: EventLoopPromise<Void>?) {
        do {
            try compressor.finishWindowedStream { buffer in
                if context.eventLoop.inEventLoop {
                    context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                } else {
                    context.eventLoop.execute {
                        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            }
        } catch {
            promise?.fail(error)
        }
    }

    /// Given a header value, extracts the q value if there is one present. If one is not present,
    /// returns the default q value, 1.0.
    private func qValueFromHeader<S: StringProtocol>(_ text: S) -> Float {
        let headerParts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard headerParts.count > 1 && headerParts[1].count > 0 else {
            return 1
        }

        // We have a Q value.
        let qValue = Float(headerParts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[1]) ?? 0
        if qValue < 0 || qValue > 1 || qValue.isNaN {
            return 0
        }
        return qValue
    }

    /// Determines the compression algorithm to use for the next response.
    private func compressionAlgorithm<S: StringProtocol>(from acceptHeaders: [S]) -> (compressor: NIOCompressor, name: String)? {
        var gzipQValue: Float = -1
        var deflateQValue: Float = -1
        var anyQValue: Float = -1

        for acceptHeader in acceptHeaders {
            if acceptHeader.hasPrefix("gzip") || acceptHeader.hasPrefix("x-gzip") {
                gzipQValue = self.qValueFromHeader(acceptHeader)
            } else if acceptHeader.hasPrefix("deflate") {
                deflateQValue = self.qValueFromHeader(acceptHeader)
            } else if acceptHeader.hasPrefix("*") {
                anyQValue = self.qValueFromHeader(acceptHeader)
            }
        }

        if gzipQValue > 0 || deflateQValue > 0 {
            if gzipQValue > deflateQValue {
                return (compressor: CompressionAlgorithm.gzip.compressor, name: "gzip")
            } else {
                return (compressor: CompressionAlgorithm.deflate.compressor, name: "deflate")
            }
        } else if anyQValue > 0 {
            // Though gzip is usually less well compressed than deflate, it has slightly
            // wider support because it's unabiguous. We therefore default to that unless
            // the client has expressed a preference.
            return (compressor: CompressionAlgorithm.gzip.compressor, name: "gzip")
        }

        return nil
    }
}
