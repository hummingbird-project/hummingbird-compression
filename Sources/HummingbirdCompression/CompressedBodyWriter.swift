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

// ResponseBodyWriter that writes a compressed version of the response to a parent writer
final class CompressedBodyWriter<ParentWriter: ResponseBodyWriter & Sendable, Allocator: CompressionAllocator>: ResponseBodyWriter where Allocator.Allocated == any NIOCompressor {
    var parentWriter: ParentWriter
    let allocator: Allocator
    let compressor: NIOCompressor
    var lastBuffer: ByteBuffer?
    let logger: Logger

    init(
        parent: ParentWriter,
        algorithm: CompressionAlgorithm,
        allocator: Allocator,
        logger: Logger
    ) async throws {
        self.parentWriter = parent
        self.allocator = allocator
        self.compressor = try await allocator.allocate(algorithm: algorithm)
        self.lastBuffer = nil
        self.logger = logger
    }

    deinit {
        do {
            try self.allocator.free(compressor)
        } catch {
            logger.error("Error finalizing compression stream: \(error) ")
        }
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

    /// Finish writing body
    /// - Parameter trailingHeaders: Any trailing headers you want to include at end
    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {
        // The last buffer must be finished
        if var lastBuffer, var window = self.compressor.window {
            // keep finishing stream until we don't get a buffer overflow
            while true {
                do {
                    try lastBuffer.compressStream(to: &window, with: self.compressor, flush: .finish)
                    try await self.parentWriter.write(window)
                    window.clear()
                    break
                } catch let error as CompressNIOError where error == .bufferOverflow {
                    try await self.parentWriter.write(window)
                    window.clear()
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
    public func compressed<Allocator: CompressionAllocator>(
        algorithm: CompressionAlgorithm,
        allocator: Allocator,
        logger: Logger
    ) async throws -> some ResponseBodyWriter where Allocator.Allocated == any NIOCompressor {
        try await CompressedBodyWriter(parent: self, algorithm: algorithm, allocator: allocator, logger: logger)
    }
}
