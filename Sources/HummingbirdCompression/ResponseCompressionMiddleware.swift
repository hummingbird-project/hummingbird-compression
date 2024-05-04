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

public struct ResponseCompressionMiddleware<Context: BaseRequestContext>: RouterMiddleware {
    public init() {}

    // ResponseBodyWriter that writes a compressed version of the response to a parent writer
    class CompressedBodyWriter: ResponseBodyWriter {
        let parentWriter: any ResponseBodyWriter
        let context: Context
        let compressor: NIOCompressor
        var lastBuffer: ByteBuffer?

        init(parent: any ResponseBodyWriter, context: Context, algorithm: CompressionAlgorithm) throws {
            self.parentWriter = parent
            self.context = context
            self.compressor = algorithm.compressor
            self.compressor.window = context.allocator.buffer(capacity: 64 * 1024)
            self.lastBuffer = nil
            try self.compressor.startStream()
        }

        deinit {
            try! self.compressor.finishStream()
        }

        /// Write response buffer
        func write(_ buffer: ByteBuffer) async throws {
            var buffer = buffer
            try await buffer.compressStream(with: self.compressor, flush: .sync) { buffer in
                try await self.parentWriter.write(buffer)
            }
            // need to store the last buffer so it can be finished once the writer is done
            self.lastBuffer = buffer
        }

        /// Finish compressed response writing
        func finish() async throws {
            // The last buffer must be finished
            if var lastBuffer {
                var window = self.compressor.window!
                // keep finishing stream until we don't get a buffer overflow
                while true {
                    do {
                        try lastBuffer.compressStream(to: &window, with: self.compressor, flush: .finish)
                        try await self.parentWriter.write(window)
                        window.moveReaderIndex(to: 0)
                        window.moveWriterIndex(to: 0)
                        break
                    } catch let error as CompressNIOError where error == .bufferOverflow {
                        try await self.parentWriter.write(window)
                        window.moveReaderIndex(to: 0)
                        window.moveWriterIndex(to: 0)
                    }
                }
            }
            self.lastBuffer = nil
        }
    }

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let (algorithm, name) = self.compressionAlgorithm(from: request.headers[values: .acceptEncoding]) else {
            return try await next(request, context)
        }
        do {
            let response = try await next(request, context)
            var editedResponse = response
            editedResponse.headers[values: .contentEncoding].append(name)
            editedResponse.headers[.contentLength] = nil
            editedResponse.headers[.transferEncoding] = "chunked"
            editedResponse.body = .withTrailingHeaders { writer in
                let compressWriter = try CompressedBodyWriter(parent: writer, context: context, algorithm: algorithm)
                // write buffers to compressed body writer. This will in affect write compressed buffers to
                // the parent writer
                let tailHeaders = try await response.body.write(compressWriter)
                // The last buffer must be finished
                try await compressWriter.finish()
                return tailHeaders
            }
            return editedResponse
        } catch {
            throw HTTPError(.internalServerError)
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
    private func compressionAlgorithm<S: StringProtocol>(from acceptContentHeaders: [S]) -> (compressor: CompressionAlgorithm, name: String)? {
        var gzipQValue: Float = -1
        var deflateQValue: Float = -1
        var anyQValue: Float = -1

        for acceptHeader in acceptContentHeaders {
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
                return (compressor: CompressionAlgorithm.gzip(), name: "gzip")
            } else {
                return (compressor: CompressionAlgorithm.zlib(), name: "deflate")
            }
        } else if anyQValue > 0 {
            // Though gzip is usually less well compressed than deflate, it has slightly
            // wider support because it's unabiguous. We therefore default to that unless
            // the client has expressed a preference.
            return (compressor: CompressionAlgorithm.gzip(), name: "gzip")
        }

        return nil
    }
}
