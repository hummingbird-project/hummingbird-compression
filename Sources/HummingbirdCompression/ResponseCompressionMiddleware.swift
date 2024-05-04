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

    class CompressWriter: ResponseBodyWriter {
        let parentWriter: any ResponseBodyWriter
        let context: Context
        let compressor: NIOCompressor
        var lastBuffer: ByteBuffer?

        init(parent: any ResponseBodyWriter, context: Context, compressor: NIOCompressor) {
            self.parentWriter = parent
            self.context = context
            self.compressor = compressor
            self.lastBuffer = nil
        }

        deinit {
            try! self.compressor.finishStream()
        }

        func write(_ buffer: ByteBuffer) async throws {
            var buffer = buffer
            try await buffer.compressStream(with: self.compressor, flush: .sync) { buffer in
                try await self.parentWriter.write(buffer)
            }
            self.lastBuffer = buffer
        }
    }

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let compressor = self.compressor(from: request.headers[values: .acceptEncoding], context: context) else {
            return try await next(request, context)
        }
        do {
            let response = try await next(request, context)
            var editedResponse = response
            try compressor.startStream()
            editedResponse.body = .withTrailingHeaders { writer in
                let compressWriter = CompressWriter(parent: writer, context: context, compressor: compressor)
                let tailHeaders = try await response.body.write(compressWriter)
                if var lastBuffer = compressWriter.lastBuffer {
                    var window = compressor.window!
                    while true {
                        do {
                            try lastBuffer.compressStream(to: &window, with: compressor, flush: .finish)
                            break
                        } catch let error as CompressNIOError where error == .bufferOverflow {
                            try await writer.write(window)
                            window.moveReaderIndex(to: 0)
                            window.moveWriterIndex(to: 0)
                        }
                    }
                    if window.readableBytes > 0 {
                        try await writer.write(window)
                        window.moveReaderIndex(to: 0)
                        window.moveWriterIndex(to: 0)
                    }
                }

                return tailHeaders
            }
            return editedResponse
        } catch {
            throw HTTPError(.internalServerError)
        }
    }

    /// Determines the compression algorithm based off content encoding header.
    private func compressor(from contentEncodingHeaders: [String], context: Context) -> NIOCompressor? {
        for encoding in contentEncodingHeaders {
            switch encoding {
            case "gzip":
                let compressor = CompressionAlgorithm.gzip().compressor
                compressor.window = context.allocator.buffer(capacity: 64 * 1024)
                return compressor
            case "deflate":
                let compressor = CompressionAlgorithm.zlib().compressor
                compressor.window = context.allocator.buffer(capacity: 64 * 1024)
                return compressor
            default:
                break
            }
        }
        return nil
    }
}
