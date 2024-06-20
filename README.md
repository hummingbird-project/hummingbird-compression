<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://github.com/hummingbird-project/hummingbird/assets/9382567/48de534f-8301-44bd-b117-dfb614909efd">
  <img src="https://github.com/hummingbird-project/hummingbird/assets/9382567/e371ead8-7ca1-43e3-8077-61d8b5eab879">
</picture>
</p>  
<p align="center">
<a href="https://swift.org">
  <img src="https://img.shields.io/badge/swift-5.9-brightgreen.svg"/>
</a>
<a href="https://github.com/hummingbird-project/hummingbird-compression/actions?query=workflow%3ACI">
  <img src="https://github.com/hummingbird-project/hummingbird-compression/actions/workflows/ci.yml/badge.svg?branch=main"/>
</a>
<a href="https://discord.gg/7ME3nZ7mP2">
  <img src="https://img.shields.io/badge/chat-discord-brightgreen.svg"/>
</a>
</p>

# Hummingbird Compression

Adds request decompression and response compression to Hummingbird

## Usage

```swift
let router = Router()
router.middlewares.add(RequestDecompressionMiddleware())
router.middlewares.add(ResponseCompressionMiddleware(minimumResponseSizeToCompress: 512))
```

Adding request decompression middleware means when a request comes in with header `content-encoding` set to `gzip` or `deflate` the server will attempt to decompress the request body. Adding response compression means when a request comes in with header `accept-encoding` set to `gzip` or `deflate` the server will compression the response body.
