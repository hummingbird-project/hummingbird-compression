import Hummingbird

extension HBHTTPServer {
    /// Add Channel Handler for decompressing request that have Content-Encoding header set to gzip or deflate
    /// - Parameter limit: Indicate the memory limit of how much to decompress to
    @discardableResult public func addRequestDecompression(
        limit: HTTPDecompressionLimit,
        threadPool: NIOThreadPool
    ) -> HBHTTPServer {
        return self.addChannelHandler(
            HTTPRequestDecompressHandler(limit: limit, threadPool: threadPool)
        )
    }

    /// Add Channel Handler for compressing responses where accept-encoding header indicates the client will accept compressed data
    @discardableResult public func addResponseCompression(threadPool: NIOThreadPool) -> HBHTTPServer {
        return self.addChannelHandler(
            HTTPResponseCompressHandler(threadPool: threadPool)
        )
    }
}
