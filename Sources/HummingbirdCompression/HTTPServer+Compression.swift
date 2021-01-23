import Hummingbird

extension HBHTTPServer {
    /// Add Channel Handler for decompressing request that have Content-Encoding header set to gzip or deflate
    /// - Parameter limit: Indicate the memory limit of how much to decompress to
    @discardableResult public func addRequestDecompression(limit: HTTPDecompressionLimit) -> HBHTTPServer {
        return self.addChildChannelHandler(HTTPRequestDecompressHandler(limit: limit), position: .afterHTTP)
    }

    /// Add Channel Handler for compressing responses where accept-encoding header indicates the client will accept compressed data
    @discardableResult public func addResponseCompression() -> HBHTTPServer {
        return self.addChildChannelHandler(
            HTTPResponseCompressHandler(),
            position: .afterHTTP
        )
    }
}
