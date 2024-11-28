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
            request.body = .init(
                asyncSequence: DecompressByteBufferSequence(
                    base: request.body,
                    algorithm: algorithm,
                    windowSize: self.windowSize,
                    logger: context.logger
                )
            )
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
struct DecompressByteBufferSequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element == ByteBuffer {
    typealias Element = ByteBuffer

    let base: Base
    let algorithm: ZlibAlgorithm
    let windowSize: Int
    let logger: Logger

    init(base: Base, algorithm: ZlibAlgorithm, windowSize: Int, logger: Logger) {
        self.base = base
        self.algorithm = algorithm
        self.windowSize = windowSize
        self.logger = logger
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        enum State {
            case uninitialized(ZlibAlgorithm, windowSize: Int)
            case decompressing(ZlibDecompressor, buffer: ByteBuffer, window: ByteBuffer)
            case done
        }

        var baseIterator: Base.AsyncIterator
        var state: State

        init(baseIterator: Base.AsyncIterator, algorithm: ZlibAlgorithm, windowSize: Int) {
            self.baseIterator = baseIterator
            self.state = .uninitialized(algorithm, windowSize: windowSize)
        }

        mutating func next() async throws -> ByteBuffer? {
            switch self.state {
            case .uninitialized(let algorithm, let windowSize):
                guard let buffer = try await self.baseIterator.next() else {
                    self.state = .done
                    return nil
                }
                let decompressor = try ZlibDecompressor(algorithm: algorithm)
                self.state = .decompressing(decompressor, buffer: buffer, window: ByteBufferAllocator().buffer(capacity: windowSize))
                return try await self.next()

            case .decompressing(let decompressor, var buffer, var window):
                do {
                    window.clear()
                    while true {
                        do {
                            try buffer.decompressStream(to: &window, with: decompressor)
                        } catch let error as CompressNIOError where error == .bufferOverflow {
                            self.state = .decompressing(decompressor, buffer: buffer, window: window)
                            return window
                        } catch let error as CompressNIOError where error == .inputBufferOverflow {
                            // can ignore CompressNIOError.inputBufferOverflow errors here
                        }

                        guard let nextBuffer = try await self.baseIterator.next() else {
                            self.state = .done
                            return window.readableBytes > 0 ? window : nil
                        }
                        buffer = nextBuffer
                    }
                } catch let error as CompressNIOError where error == .corruptData {
                    throw HTTPError(.badRequest, message: "Corrupt compression data.")
                } catch {
                    throw HTTPError(.badRequest, message: "Data decompression failed.")
                }

            case .done:
                return nil
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        .init(baseIterator: self.base.makeAsyncIterator(), algorithm: self.algorithm, windowSize: self.windowSize)
    }
}
