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

extension HBApplication {
    /// Add Channel Handler for decompressing request that have Content-Encoding header set to gzip or deflate
    /// - Parameter limit: Indicate the memory limit of how much to decompress to
    public func addRequestDecompression(useThreadPool: Bool, limit: HTTPDecompressionLimit) {
        precondition(
            self.configuration.enableHttpPipelining || useThreadPool == false,
            "Request decompression on the thread pool requires HTTP pipelining assist to be enabled"
        )
        self.server.addRequestDecompression(limit: limit, threadPool: nil)
    }

    /// Add Channel Handler for compressing responses where accept-encoding header indicates the client will accept compressed data
    public func addResponseCompression() {
        precondition(self.configuration.enableHttpPipelining, "Response compression does not work without HTTP pipelining assist enabled")
        self.server.addResponseCompression(threadPool: self.threadPool)
    }
}
