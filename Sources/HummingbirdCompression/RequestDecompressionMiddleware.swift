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

public struct RequestDecompressionMiddleware<Context: BaseRequestContext>: RouterMiddleware {
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
                windowSize: self.windowSize
            ))
            let response = try await next(request, context)
            return response
        } else {
            return try await next(request, context)
        }
    }

    /// Determines the decompression algorithm based off content encoding header.
    private func algorithm(from contentEncodingHeaders: [String]) -> CompressionAlgorithm? {
        for encoding in contentEncodingHeaders {
            switch encoding {
            case "gzip":
                return CompressionAlgorithm.gzip()
            case "deflate":
                return CompressionAlgorithm.zlib()
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
    let algorithm: CompressionAlgorithm
    let windowSize: Int

    class AsyncIterator: AsyncIteratorProtocol {
        var baseIterator: Base.AsyncIterator
        let decompressor: NIODecompressor
        var currentBuffer: ByteBuffer?
        var window: ByteBuffer

        init(baseIterator: Base.AsyncIterator, algorithm: CompressionAlgorithm, windowSize: Int) {
            self.baseIterator = baseIterator
            self.decompressor = algorithm.decompressor
            self.window = ByteBufferAllocator().buffer(capacity: windowSize)
            self.currentBuffer = nil
            try! self.decompressor.startStream()
        }

        deinit {
            try! self.decompressor.finishStream()
        }

        func next() async throws -> ByteBuffer? {
            if self.currentBuffer == nil {
                self.currentBuffer = try await self.baseIterator.next()
            }
            self.window.moveReaderIndex(to: 0)
            self.window.moveWriterIndex(to: 0)
            while var buffer = self.currentBuffer {
                do {
                    try buffer.decompressStream(to: &self.window, with: self.decompressor)
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
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        .init(baseIterator: self.base.makeAsyncIterator(), algorithm: self.algorithm, windowSize: self.windowSize)
    }
}
