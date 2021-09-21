//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Hummingbird
import NIOPosix

extension HBApplication {
    /// Indicate where the response compression tasks should be executed
    public enum RequestCompressionExecutionPreference {
        /// run decompression tasks on the EventLoop
        case onEventLoop
        /// run decompression tasks on application thread pool
        case onThreadPool
    }

    /// Add Channel Handler for decompressing request that have Content-Encoding header set to gzip or deflate
    /// - Parameter limit: Indicate the memory limit of how much to decompress to
    public func addRequestDecompression(execute: RequestCompressionExecutionPreference, limit: HTTPDecompressionLimit) {
        precondition(
            self.configuration.enableHttpPipelining || execute == .onEventLoop,
            "Request decompression on the thread pool requires HTTP pipelining assist to be enabled"
        )
        self.server.addRequestDecompression(limit: limit, threadPool: execute == .onThreadPool ? self.threadPool : nil)
    }

    /// Indicate where the response compression tasks should be executed
    public enum ResponseCompressionExecutionPreference: Equatable {
        /// run all compression tasks on the EventLoop
        case onEventLoop
        /// run compression tasks that are larger than `threshold` bytes on application thread pool
        case onThreadPool(threshold: Int)
    }

    /// Add Channel Handler for compressing responses where accept-encoding header indicates the client will accept compressed data
    public func addResponseCompression(execute: ResponseCompressionExecutionPreference) {
        precondition(
            self.configuration.enableHttpPipelining || execute == .onEventLoop,
            "Response compression on the thread pool requires HTTP pipelining assist to be enabled"
        )
        switch execute {
        case .onEventLoop:
            self.server.addResponseCompression(threadPool: nil)
        case .onThreadPool(let threshold):
            self.server.addResponseCompression(threadPool: self.threadPool, threadPoolThreshold: threshold)
        }
    }
}
