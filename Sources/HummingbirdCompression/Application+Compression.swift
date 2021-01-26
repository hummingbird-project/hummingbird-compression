import Hummingbird

extension HBApplication {
    /// Add Channel Handler for decompressing request that have Content-Encoding header set to gzip or deflate
    /// - Parameter limit: Indicate the memory limit of how much to decompress to
    public func addRequestDecompression(limit: HTTPDecompressionLimit) {
        self.server.addRequestDecompression(limit: limit)
    }

    /// Add Channel Handler for compressing responses where accept-encoding header indicates the client will accept compressed data
    public func addResponseCompression() {
        self.server.addResponseCompression()
    }
}
