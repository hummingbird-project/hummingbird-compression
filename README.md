# Hummingbird Compression

Adds request decompression and response compression to Hummingbird

## Usage

```swift
let app = HBApplication()
// run response compression on application thread pool when buffer is 
// larget than 32768 bytes otherwise run it on the eventloop
app.addResponseCompression(execute: .onThreadPool(threshold: 32768))
// run request decompression on eventloop with no limit to the size
// of data that can be decompressed
app.addRequestDecompression(execute: .onEventLoop, limit: .none)
```

Adding request decompression means when a request comes in with header `content-encoding` set to `gzip` or `deflate` the server will attempt to decompress the request body. Adding response compression means when a request comes in with header `accept-encoding` set to `gzip` or `deflate` the server will compression the response body.
