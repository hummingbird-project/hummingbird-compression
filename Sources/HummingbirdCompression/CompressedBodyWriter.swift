//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2025 the Hummingbird authors
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
import NIOConcurrencyHelpers

// ResponseBodyWriter that writes a compressed version of the response to a parent writer
final class CompressedBodyWriter<ParentWriter: ResponseBodyWriter & Sendable, Allocator: ZlibAllocator>: ResponseBodyWriter
where Allocator.Value == ZlibCompressor {
    var parentWriter: ParentWriter
    private var compressor: AllocatedValue<Allocator>
    private var window: ByteBuffer
    var lastBuffer: ByteBuffer?
    let logger: Logger

    init(
        parent: ParentWriter,
        allocator: Allocator,
        windowSize: Int,
        logger: Logger
    ) throws {
        self.parentWriter = parent
        self.compressor = try .init(allocator: allocator)
        self.window = ByteBufferAllocator().buffer(capacity: windowSize)
        self.lastBuffer = nil
        self.logger = logger
    }

    /// Write response buffer
    func write(_ buffer: ByteBuffer) async throws {
        var buffer = buffer
        try await buffer.compressStream(with: compressor.value, window: &self.window, flush: .sync) { buffer in
            try await self.parentWriter.write(buffer)
        }
        // need to store the last buffer so it can be finished once the writer is done
        self.lastBuffer = buffer
    }

    /// Finish writing body
    /// - Parameter trailingHeaders: Any trailing headers you want to include at end
    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {
        // The last buffer must be finished
        if var lastBuffer {
            // keep finishing stream until we don't get a buffer overflow
            while true {
                do {
                    try lastBuffer.compressStream(to: &self.window, with: compressor.value, flush: .finish)
                    try await self.parentWriter.write(self.window)
                    self.window.clear()
                    break
                } catch let error as CompressNIOError where error == .bufferOverflow {
                    try await self.parentWriter.write(self.window)
                    self.window.clear()
                }
            }
        }
        self.lastBuffer = nil
        try await self.parentWriter.finish(trailingHeaders)
    }
}

extension ResponseBodyWriter {
    ///  Return ``HummingbirdCore/ResponseBodyWriter`` that compresses the contents of this ResponseBodyWriter
    /// - Parameters:
    ///   - algorithm: Compression algorithm
    ///   - windowSize: Window size (in bytes) to use when compressing data
    ///   - logger: Logger used to output compression errors
    /// - Returns: new ``HummingbirdCore/ResponseBodyWriter``
    func compressed<Allocator: ZlibAllocator<ZlibCompressor>>(
        compressorPool: Allocator,
        windowSize: Int,
        logger: Logger
    ) throws -> some ResponseBodyWriter {
        try CompressedBodyWriter(parent: self, allocator: compressorPool, windowSize: windowSize, logger: logger)
    }

    ///  Return ``HummingbirdCore/ResponseBodyWriter`` that compresses the contents of this ResponseBodyWriter
    /// - Parameters:
    ///   - algorithm: Compression algorithm
    ///   - configuration: Zlib configuration
    ///   - windowSize: Window size (in bytes) to use when compressing data
    ///   - logger: Logger used to output compression errors
    /// - Returns: new ``HummingbirdCore/ResponseBodyWriter``
    public func compressed(
        algorithm: ZlibAlgorithm,
        configuration: ZlibConfiguration,
        windowSize: Int,
        logger: Logger
    ) throws -> some ResponseBodyWriter {
        try compressed(
            compressorPool: ZlibCompressorAllocator(algorithm: algorithm, configuration: configuration),
            windowSize: windowSize,
            logger: logger
        )
    }
}

extension ZlibCompressor: PoolReusable {}
struct ZlibCompressorAllocator: ZlibAllocator, Sendable {
    typealias Value = ZlibCompressor
    let algorithm: ZlibAlgorithm
    let configuration: ZlibConfiguration

    func allocate() throws -> ZlibCompressor {
        try ZlibCompressor(algorithm: algorithm, configuration: configuration)
    }

    func free(_ compressor: inout ZlibCompressor?) {
        compressor = nil
    }
}
