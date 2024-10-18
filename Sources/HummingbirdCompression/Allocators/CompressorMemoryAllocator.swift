//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2024 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CompressNIO
import NIOCore

public struct CompressorMemoryAllocator: Allocator {
    public typealias Object = NIOCompressor
    public struct Parameters {
        let algorithm: CompressionAlgorithm
    }

    let windowSize: Int

    public init(windowSize: Int) {
        self.windowSize = windowSize
    }

    public func allocate(_ parameters: Parameters) async throws -> Object {
        let compressor = parameters.algorithm.compressor
        compressor.window = ByteBufferAllocator().buffer(capacity: self.windowSize)
        try compressor.startStream()
        return compressor
    }

    public func free(_ object: Object) throws {
        try object.finishStream()
    }
}