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

public struct HBRequestDecompressionMiddleware<Context: HBBaseRequestContext>: HBMiddlewareProtocol {
    public init() {}
    
    public func handle(_ request: HBRequest, context: Context, next: (HBRequest, Context) async throws -> HBResponse) async throws -> HBResponse {
        guard let decompressor = self.decompressor(from: request.headers[values: .contentEncoding], context: context) else {
            return try await next(request, context)
        }
        do {
            try decompressor.startStream()
        } catch {
            throw HBHTTPError(.internalServerError)
        }
        return try await withThrowingTaskGroup(of: Void.self) { group in
            let (stream, source) = HBRequestBody.makeStream()
            var compressedRequest = request
            compressedRequest.body = stream
            group.addTask {
                for try await var buffer in request.body {
                    try await buffer.decompressStream(with: decompressor) { buffer in
                        try await source.yield(buffer)
                    }
                }
                try decompressor.finishStream()
                source.finish()
            }
            let response = try await next(compressedRequest, context)
            return response
        }
    }

    /// Determines the decompression algorithm based off content encoding header.
    private func decompressor(from contentEncodingHeaders: [String], context: Context) -> NIODecompressor? {
        for encoding in contentEncodingHeaders {
            switch encoding {
            case "gzip":
                let decompressor = CompressionAlgorithm.gzip().decompressor
                decompressor.window = context.allocator.buffer(capacity: 64*1024)
                return decompressor
            case "deflate":
                let decompressor = CompressionAlgorithm.zlib().decompressor
                decompressor.window = context.allocator.buffer(capacity: 64*1024)
                return decompressor
            default:
                break
            }
        }
        return nil
    }
}
