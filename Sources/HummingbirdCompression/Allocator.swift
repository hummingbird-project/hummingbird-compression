//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2025 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOConcurrencyHelpers

protocol ZlibAllocator<Value> {
    associatedtype Value
    func allocate() throws -> Value
    func free(_ compressor: inout Value?) throws
}

protocol PoolReusable {
    func reset() throws
}

struct PoolAllocator<BaseAllocator: ZlibAllocator>: ZlibAllocator where BaseAllocator.Value: PoolReusable {
    typealias Value = BaseAllocator.Value
    @usableFromInline
    let base: BaseAllocator
    @usableFromInline
    let poolSize: Int
    @usableFromInline
    let values: NIOLockedValueBox<[Value]>

    @inlinable
    init(size: Int, base: BaseAllocator) {
        self.base = base
        self.poolSize = size
        self.values = .init([])
    }

    @inlinable
    func allocate() throws -> Value {
        let value = self.values.withLockedValue {
            $0.popLast()
        }
        if let value {
            return value
        }
        return try base.allocate()
    }

    @inlinable
    func free(_ value: inout Value?) throws {
        guard let nonOptionalValue = value else { preconditionFailure("Cannot ball free twice on a compressor") }
        try self.values.withLockedValue {
            if $0.count < poolSize {
                try nonOptionalValue.reset()
                $0.append(nonOptionalValue)
            }
        }
        try base.free(&value)
    }
}
