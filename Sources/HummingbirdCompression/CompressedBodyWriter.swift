//
// This source file is part of the Hummingbird server framework project
// Copyright (c) the Hummingbird authors
//
// See LICENSE.txt for license information
// SPDX-License-Identifier: Apache-2.0
//

import CompressNIO
import Hummingbird
import Logging

// ResponseBodyWriter that writes a compressed version of the response to a parent writer
final class CompressedBodyWriter<ParentWriter: ResponseBodyWriter & Sendable>: ResponseBodyWriter {
    var parentWriter: ParentWriter
    private let compressor: ZlibCompressor
    private var window: ByteBuffer
    var lastBuffer: ByteBuffer?
    let logger: Logger

    init(
        parent: ParentWriter,
        algorithm: ZlibAlgorithm,
        configuration: ZlibConfiguration,
        windowSize: Int,
        logger: Logger
    ) throws {
        self.parentWriter = parent
        self.compressor = try ZlibCompressor(algorithm: algorithm, configuration: configuration)
        self.window = ByteBufferAllocator().buffer(capacity: windowSize)
        self.lastBuffer = nil
        self.logger = logger
    }

    /// Write response buffer
    func write(_ buffer: ByteBuffer) async throws {
        var buffer = buffer
        try await buffer.compressStream(with: self.compressor, window: &self.window, flush: .sync) { buffer in
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
                    try lastBuffer.compressStream(to: &self.window, with: self.compressor, flush: .finish)
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
    public func compressed(
        algorithm: ZlibAlgorithm,
        configuration: ZlibConfiguration,
        windowSize: Int,
        logger: Logger
    ) throws -> some ResponseBodyWriter {
        try CompressedBodyWriter(parent: self, algorithm: algorithm, configuration: configuration, windowSize: windowSize, logger: logger)
    }
}
