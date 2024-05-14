# Hummingbird Compression

Adds request decompression and response compression to Hummingbird

## Usage

```swift
let router = Router()
router.middlewares.add(RequestDecompressionMiddleware())
router.middlewares.add(ResponseCompressionMiddleware(minimumResponseSizeToCompress: 512))
```

Adding request decompression middleware means when a request comes in with header `content-encoding` set to `gzip` or `deflate` the server will attempt to decompress the request body. Adding response compression means when a request comes in with header `accept-encoding` set to `gzip` or `deflate` the server will compression the response body.
