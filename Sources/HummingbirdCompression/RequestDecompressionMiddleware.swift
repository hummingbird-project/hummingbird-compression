//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2024 the Hummingbird authors
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
import Logging

/// Middleware for decompressing request bodies
///
/// if the content-encoding header is set to gzip or deflate then the middleware will attempt
/// to decompress the contents of the request body and pass that down the middleware chain.
public struct RequestDecompressionMiddleware<Context: RequestContext>: RouterMiddleware {
    /// decompression window size
    let windowSize: Int

    /// Initialize RequestDecompressionMiddleware
    /// - Parameter windowSize: Decompression window size
    public init(windowSize: Int = 32768) {
        self.windowSize = windowSize
    }

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if let algorithm = algorithm(from: request.headers[values: .contentEncoding]) {
            var request = request
            request.body = .init(asyncSequence: DecompressByteBufferSequence(
                base: request.body,
                algorithm: algorithm,
                windowSize: self.windowSize,
                logger: context.logger
            ))
            let response = try await next(request, context)
            return response
        } else {
            return try await next(request, context)
        }
    }

    /// Determines the decompression algorithm based off content encoding header.
    private func algorithm(from contentEncodingHeaders: [String]) -> ZlibAlgorithm? {
        for encoding in contentEncodingHeaders {
            switch encoding {
            case "gzip":
                return .gzip
            case "deflate":
                return .zlib
            default:
                break
            }
        }
        return nil
    }
}

/// AsyncSequence of decompressed ByteBuffers
final class DecompressByteBufferSequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element == ByteBuffer {
    typealias Element = ByteBuffer

    let base: Base
    var algorithm: ZlibAlgorithm
    let windowSize: Int
    let logger: Logger

    init(base: Base, algorithm: ZlibAlgorithm, windowSize: Int, logger: Logger) {
        self.base = base
        self.algorithm = algorithm
        self.windowSize = windowSize
        self.logger = logger
    }

    class AsyncIterator: AsyncIteratorProtocol {
        var baseIterator: Base.AsyncIterator
        var decompressor: ZlibDecompressor
        var currentBuffer: ByteBuffer?
        var window: ByteBuffer
        let logger: Logger

        init(baseIterator: Base.AsyncIterator, algorithm: ZlibAlgorithm, windowSize: Int, logger: Logger) {
            self.baseIterator = baseIterator
            self.decompressor = ZlibDecompressor(algorithm: algorithm)
            self.window = ByteBufferAllocator().buffer(capacity: windowSize)
            self.currentBuffer = nil
            self.logger = logger
            do {
                try self.decompressor.startStream()
            } catch {
                logger.error("Error initializing decompression stream: \(error) ")
            }
        }

        deinit {
            do {
                try self.decompressor.finishStream()
            } catch {
                logger.error("Error finalizing decompression stream: \(error) ")
            }
        }

        func next() async throws -> ByteBuffer? {
            do {
                if self.currentBuffer == nil {
                    self.currentBuffer = try await self.baseIterator.next()
                }
                self.window.clear()
                while var buffer = self.currentBuffer {
                    do {
                        try buffer.decompressStream(to: &self.window, with: &self.decompressor)
                    } catch let error as CompressNIOError where error == .bufferOverflow {
                        self.currentBuffer = buffer
                        return self.window
                    } catch let error as CompressNIOError where error == .inputBufferOverflow {
                        // can ignore CompressNIOError.inputBufferOverflow errors here
                    }

                    self.currentBuffer = try await self.baseIterator.next()
                }
                self.currentBuffer = nil
                return self.window.readableBytes > 0 ? self.window : nil
            } catch let error as CompressNIOError where error == .corruptData {
                throw HTTPError(.badRequest, message: "Corrupt compression data.")
            } catch {
                throw HTTPError(.badRequest, message: "Data decompression failed.")
            }
        }
    }

    consuming func makeAsyncIterator() -> AsyncIterator {
        .init(baseIterator: self.base.makeAsyncIterator(), algorithm: self.algorithm, windowSize: self.windowSize, logger: self.logger)
    }
}
