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

/// Middleware for compressing response bodies
///
/// If the accept-encoding header in request is set to gzip or deflate and the response body
/// is of at least a minimum size then the middleware will return a response with a compressed
/// version of the response body that it received.
public struct ResponseCompressionMiddleware<Context: RequestContext, Allocator: CompressorAllocator>: RouterMiddleware {
    /// compression window size
    let allocator: Allocator
    /// minimum size of response body to compress
    let minimumResponseSizeToCompress: Int
    /// Zlib configuration
    let zlibConfiguration: ZlibConfiguration

    /// Initialize ResponseCompressionMiddleware
    /// - Parameters:
    ///   - windowSize: Compression window size
    ///   - minimumResponseSizeToCompress: Minimum size of response before applying compression
    ///   - zlibCompressionLevel: zlib compression level to use. Value between 0 and 9 where 1 is fastest, 9 is best compression and
    ///         0 is no compression.
    ///   - zlibMemoryLevel: Amount of memory to use when compressing. Less memory will mean the compression will take longer
    ///         and compression level will be reduced. Value between 1 - 9 where 1 is least amount of memory.
    public init(
        allocator: Allocator = CompressorMemoryAllocator(windowSize: 32768),
        minimumResponseSizeToCompress: Int = 1024,
        zlibCompressionLevel: Int? = nil,
        zlibMemoryLevel: Int? = nil
    ) {
        self.allocator = allocator
        self.minimumResponseSizeToCompress = minimumResponseSizeToCompress
        self.zlibConfiguration = .init(
            compressionLevel: numericCast(zlibCompressionLevel ?? -1), // -1 indicates use the default compression level set by the library
            memoryLevel: numericCast(zlibMemoryLevel ?? 8) // 8 is the default value for the library
        )
    }

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let response = try await next(request, context)
        // if content length is less than the minimum content length require before compression is applied then
        // just return the response now
        if let contentLength = response.body.contentLength {
            guard contentLength > self.minimumResponseSizeToCompress else {
                return response
            }
        }
        guard let (algorithm, name) = self.compressionAlgorithm(from: request.headers[values: .acceptEncoding]) else {
            return response
        }
        var editedResponse = response
        editedResponse.headers[values: .contentEncoding].append(name)
        editedResponse.headers[.contentLength] = nil
        editedResponse.headers[.transferEncoding] = "chunked"
        editedResponse.body = .init { writer in
            let compressWriter = try await writer.compressed(
                algorithm: algorithm,
                allocator: self.allocator,
                logger: context.logger
            )
            try await response.body.write(compressWriter)
        }
        return editedResponse
    }

    /// Given a header value, extracts the q value if there is one present. If one is not present,
    /// returns the default q value, 1.0.
    private func qValueFromHeader(_ text: some StringProtocol) -> Float {
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
    private func compressionAlgorithm(from acceptContentHeaders: [some StringProtocol]) -> (compressor: CompressionAlgorithm, name: String)? {
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
                return (compressor: CompressionAlgorithm.gzip(configuration: self.zlibConfiguration), name: "gzip")
            } else {
                return (compressor: CompressionAlgorithm.zlib(configuration: self.zlibConfiguration), name: "deflate")
            }
        } else if anyQValue > 0 {
            // Though gzip is usually less well compressed than deflate, it has slightly
            // wider support because it's unabiguous. We therefore default to that unless
            // the client has expressed a preference.
            return (compressor: CompressionAlgorithm.gzip(configuration: self.zlibConfiguration), name: "gzip")
        }

        return nil
    }
}
