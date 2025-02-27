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
    /// Decompression window size. This is not the internal zlib window
    let windowSize: Int
    /// Pool of gzip decompressors
    let gzipDecompressorPool: PoolAllocator<ZlibDecompressorAllocator>
    /// Pool of deflate compressors
    let deflateDecompressorPool: PoolAllocator<ZlibDecompressorAllocator>

    /// Initialize RequestDecompressionMiddleware
    /// - Parameters
    ///    - windowSize: Decompression window size
    ///    - gzipDecompressorPoolSize: Maximum size of the gzip decompressor pool
    ///    - deflateDecompressorPoolSize: Maximum size of the deflate decompressor pool
    public init(
        windowSize: Int = 32768,
        gzipDecompressorPoolSize: Int,
        deflateDecompressorPoolSize: Int
    ) {
        self.windowSize = windowSize
        self.gzipDecompressorPool = .init(size: gzipDecompressorPoolSize, base: .init(algorithm: .gzip, windowSize: 15))
        self.deflateDecompressorPool = .init(size: deflateDecompressorPoolSize, base: .init(algorithm: .zlib, windowSize: 15))
    }

    /// Initialize RequestDecompressionMiddleware
    /// - Parameter windowSize: Decompression window size
    public init(windowSize: Int = 32768) {
        self.init(windowSize: windowSize, gzipDecompressorPoolSize: 16, deflateDecompressorPoolSize: 16)
    }

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if let pool = algorithm(from: request.headers[values: .contentEncoding]) {
            var request = request
            request.body = .init(
                asyncSequence: DecompressByteBufferSequence(
                    base: request.body,
                    allocator: pool,
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
    private func algorithm(from contentEncodingHeaders: [String]) -> PoolAllocator<ZlibDecompressorAllocator>? {
        for encoding in contentEncodingHeaders {
            switch encoding {
            case "gzip":
                return self.gzipDecompressorPool
            case "deflate":
                return self.deflateDecompressorPool
            default:
                break
            }
        }
        return nil
    }
}

/// AsyncSequence of decompressed ByteBuffers
struct DecompressByteBufferSequence<Base: AsyncSequence & Sendable, Allocator: ZlibAllocator>: AsyncSequence, Sendable
where Base.Element == ByteBuffer, Allocator.Value == ZlibDecompressor, Allocator: Sendable {
    typealias Element = ByteBuffer

    let base: Base
    let allocator: Allocator
    let windowSize: Int
    let logger: Logger

    init(base: Base, allocator: Allocator, windowSize: Int, logger: Logger) {
        self.base = base
        self.allocator = allocator
        self.windowSize = windowSize
        self.logger = logger
    }

    class AsyncIterator: AsyncIteratorProtocol {
        enum State {
            case uninitialized(Allocator, windowSize: Int)
            case decompressing(DecompressorWrapper, buffer: ByteBuffer, window: ByteBuffer)
            case done
        }

        var baseIterator: Base.AsyncIterator
        var state: State

        init(baseIterator: Base.AsyncIterator, allocator: Allocator, windowSize: Int) {
            self.baseIterator = baseIterator
            self.state = .uninitialized(allocator, windowSize: windowSize)
        }

        func next() async throws -> ByteBuffer? {
            switch self.state {
            case .uninitialized(let allocator, let windowSize):
                guard let buffer = try await self.baseIterator.next() else {
                    self.state = .done
                    return nil
                }
                let decompressor = try DecompressorWrapper(allocator: allocator)
                self.state = .decompressing(decompressor, buffer: buffer, window: ByteBufferAllocator().buffer(capacity: windowSize))
                return try await self.next()

            case .decompressing(let decompressor, var buffer, var window):
                do {
                    window.clear()
                    while true {
                        do {
                            try buffer.decompressStream(to: &window, with: decompressor.wrapped)
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

        /// Wrapper for decompressor that uses allocator to manage its lifecycle
        class DecompressorWrapper {
            let wrapped: ZlibDecompressor
            let allocator: Allocator

            init(allocator: Allocator) throws {
                self.allocator = allocator
                self.wrapped = try allocator.allocate()
            }

            deinit {
                var optionalValue: ZlibDecompressor? = self.wrapped
                self.allocator.free(&optionalValue)
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        .init(baseIterator: self.base.makeAsyncIterator(), allocator: self.allocator, windowSize: self.windowSize)
    }
}

extension ZlibDecompressor: PoolReusable {}
struct ZlibDecompressorAllocator: ZlibAllocator, Sendable {
    typealias Value = ZlibDecompressor
    let algorithm: ZlibAlgorithm
    let windowSize: Int32

    func allocate() throws -> ZlibDecompressor {
        try ZlibDecompressor(algorithm: algorithm, windowSize: self.windowSize)
    }

    func free(_ decompressor: inout ZlibDecompressor?) {
        decompressor = nil
    }
}
