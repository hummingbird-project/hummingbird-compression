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

/// Protocol for allocator of object
public protocol CompressionAllocator<Allocated>: Sendable {
    associatedtype Allocated

    func allocate(algorithm: CompressionAlgorithm) async throws -> Allocated
    func free(_: Allocated) throws
}

public protocol CompressorAllocator: CompressionAllocator where Allocated == any NIOCompressor {}
public protocol DecompressorAllocator: CompressionAllocator where Allocated == any NIODecompressor {}
