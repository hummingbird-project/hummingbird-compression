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
    func free(_ compressor: inout Value?)
}

/// Wrapper for value that uses allocator to manage its lifecycle
class AllocatedValue<Allocator: ZlibAllocator> {
    let value: Allocator.Value
    let allocator: Allocator

    init(allocator: Allocator) throws {
        self.allocator = allocator
        self.value = try allocator.allocate()
    }

    deinit {
        var optionalValue: Allocator.Value? = self.value
        self.allocator.free(&optionalValue)
    }
}

/// Type that can be used with the PoolAllocator
protocol PoolReusable {
    func reset() throws
}

/// Allocator that keeps a pool of values around to be re-used.
///
/// It will use a value from the pool if it isnt empty. Otherwise it will
/// allocate a new value. When values are freed they are passed back to the pool
/// up until the point where the pool grows to its maximum size.
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
            try value.reset()
            return value
        }
        return try base.allocate()
    }

    @inlinable
    func free(_ value: inout Value?) {
        guard let nonOptionalValue = value else { preconditionFailure("Cannot ball free twice on a compressor") }
        self.values.withLockedValue {
            if $0.count < poolSize {
                $0.append(nonOptionalValue)
            }
        }
        base.free(&value)
    }
}
