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
public struct ResponseCompressionMiddleware<Context: RequestContext>: RouterMiddleware {
    /// compression window size
    let windowSize: Int
    /// minimum size of response body to compress
    let minimumResponseSizeToCompress: Int
    /// Zlib configuration
    let zlibConfiguration: ZlibConfiguration
    /// Pool of gzip compressors
    let gzipCompressorPool: PoolAllocator<ZlibCompressorAllocator>
    /// Pool of deflate compressors
    let deflateCompressorPool: PoolAllocator<ZlibCompressorAllocator>

    /// Initialize ResponseCompressionMiddleware
    /// - Parameters:
    ///   - windowSize: Compression window size
    ///   - minimumResponseSizeToCompress: Minimum size of response before applying compression
    ///   - gzipCompressorPoolSize: Maximum size of gzip compressor pool
    ///   - deflateCompressorPoolSize: Maximum size of deflate compressor pool
    ///   - zlibCompressionLevel: zlib compression level.
    ///   - zlibMemoryLevel: Amount of memory to allocated for compression state.
    public init(
        windowSize: Int = 32768,
        minimumResponseSizeToCompress: Int = 1024,
        gzipCompressorPoolSize: Int = 16,
        deflateCompressorPoolSize: Int = 16,
        zlibCompressionLevel: ZlibConfiguration.CompressionLevel = .defaultCompressionLevel,
        zlibMemoryLevel: ZlibConfiguration.MemoryLevel = .defaultMemoryLevel
    ) {
        self.windowSize = windowSize
        self.minimumResponseSizeToCompress = minimumResponseSizeToCompress
        self.zlibConfiguration = .init(
            compressionLevel: zlibCompressionLevel,
            memoryLevel: zlibMemoryLevel
        )
        self.gzipCompressorPool = .init(size: gzipCompressorPoolSize, base: .init(algorithm: .gzip, configuration: self.zlibConfiguration))
        // HTTP deflate is actually zlib compression
        self.deflateCompressorPool = .init(size: deflateCompressorPoolSize, base: .init(algorithm: .zlib, configuration: self.zlibConfiguration))
    }

    /// Initialize ResponseCompressionMiddleware
    /// - Parameters:
    ///   - windowSize: Compression window size
    ///   - minimumResponseSizeToCompress: Minimum size of response before applying compression
    ///   - zlibCompressionLevel: zlib compression level.
    ///   - zlibMemoryLevel: Amount of memory to allocated for compression state.
    public init(
        windowSize: Int = 32768,
        minimumResponseSizeToCompress: Int = 1024,
        zlibCompressionLevel: ZlibConfiguration.CompressionLevel = .defaultCompressionLevel,
        zlibMemoryLevel: ZlibConfiguration.MemoryLevel = .defaultMemoryLevel
    ) {
        self.init(
            windowSize: windowSize,
            minimumResponseSizeToCompress: minimumResponseSizeToCompress,
            gzipCompressorPoolSize: 16,
            deflateCompressorPoolSize: 16,
            zlibCompressionLevel: zlibCompressionLevel,
            zlibMemoryLevel: zlibMemoryLevel
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
        guard let (pool, name) = self.compressionAlgorithm(from: request.headers[values: .acceptEncoding]) else {
            return response
        }
        var editedResponse = response
        editedResponse.headers[values: .contentEncoding].append(name)
        editedResponse.headers[.contentLength] = nil
        editedResponse.headers[.transferEncoding] = "chunked"
        editedResponse.body = .init { writer in
            let compressWriter = try writer.compressed(
                compressorPool: pool,
                windowSize: self.windowSize,
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
    private func compressionAlgorithm(
        from acceptContentHeaders: [some StringProtocol]
    ) -> (pool: PoolAllocator<ZlibCompressorAllocator>, name: String)? {
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
                return (pool: self.gzipCompressorPool, name: "gzip")
            } else {
                return (pool: self.deflateCompressorPool, name: "deflate")
            }
        } else if anyQValue > 0 {
            // Though gzip is usually less well compressed than deflate, it has slightly
            // wider support because it's unabiguous. We therefore default to that unless
            // the client has expressed a preference.
            return (pool: self.gzipCompressorPool, name: "gzip")
        }

        return nil
    }
}
