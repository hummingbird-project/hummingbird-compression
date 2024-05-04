//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2024 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CompressNIO
import Hummingbird
/*
 public struct ResponseCompressionMiddleware<Context: BaseRequestContext>: HBMiddlewareProtocol {
     public init() {}

     class CompressWriter: ResponseBodyWriter {
         let parentWriter: any ResponseBodyWriter
         let context: Context
         let compressor: NIOCompressor

         init(parent: any ResponseBodyWriter, context: Context, compressor: NIOCompressor) {
             self.parentWriter = parent
             self.context = context
             self.compressor = compressor
         }

         deinit {}

         func write(_ buffer: ByteBuffer) async throws {
             let output = self.context.allocator.buffer(bytes: buffer.readableBytesView.map { $0 ^ 255 })
             try await self.parentWriter.write(output)
         }
     }

     public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
         guard let compressor = self.compressor(from: request.headers[values: .acceptEncoding], context: context) else {
             return try await next(request, context)
         }
         do {
             try compressor.startStream()
         } catch {
             throw HTTPError(.internalServerError)
         }
     }

     /// Determines the compression algorithm based off content encoding header.
     private func compressor(from contentEncodingHeaders: [String], context: Context) -> NIOCompressor? {
         for encoding in contentEncodingHeaders {
             switch encoding {
             case "gzip":
                 let compressor = CompressionAlgorithm.gzip().compressor
                 compressor.window = context.allocator.buffer(capacity: 64 * 1024)
                 return compressor
             case "deflate":
                 let compressor = CompressionAlgorithm.zlib().compressor
                 compressor.window = context.allocator.buffer(capacity: 64 * 1024)
                 return compressor
             default:
                 break
             }
         }
         return nil
     }
 }
 */
