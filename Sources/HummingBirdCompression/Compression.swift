import HummingBird

extension HTTPServer {
    @discardableResult public func addRequestDecompression() -> HTTPServer {
        return self.addChildChannelHandler(HTTPRequestDecompressHandler(), position: .afterHTTP)
    }

    @discardableResult public func addResponseCompression() -> HTTPServer {
        return self.addChildChannelHandler(
            HTTPResponseCompressHandler(),
            position: .afterHTTP
        )
    }
}
