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

extension HBHTTPServer {
    /// Add Channel Handler for decompressing request that have Content-Encoding header set to gzip or deflate
    /// - Parameter limit: Indicate the memory limit of how much to decompress to
    @discardableResult public func addRequestDecompression(
        limit: HTTPDecompressionLimit,
        threadPool: NIOThreadPool?
    ) -> HBHTTPServer {
        return self.addChannelHandler(
            HTTPRequestDecompressHandler(limit: limit, threadPool: threadPool)
        )
    }

    /// Add Channel Handler for compressing responses where accept-encoding header indicates the client will accept compressed data
    @discardableResult public func addResponseCompression(threadPool: NIOThreadPool?, threadPoolThreshold: Int = 0) -> HBHTTPServer {
        return self.addChannelHandler(
            HTTPResponseCompressHandler(threadPool: threadPool, threadPoolThreshold: threadPoolThreshold)
        )
    }
}
