//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2023 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTPTypes
import ServiceLifecycle

/// Protocol for HTTP channels
public protocol HTTPChannelHandler: ServerChildChannel {
    typealias Responder = @Sendable (Request, Channel) async -> Response
    var responder: Responder { get }
}

/// Internal error thrown when an unexpected HTTP part is received eg we didn't receive
/// a head part when we expected one
@usableFromInline
enum HTTPChannelError: Error {
    case unexpectedHTTPPart(HTTPRequestPart)
}

enum HTTPState: Int, Sendable {
    case idle
    case processing
    case cancelled
}

extension HTTPChannelHandler {
    public func handleHTTP(asyncChannel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, logger: Logger) async {
        let processingRequest = NIOLockedValueBox(HTTPState.idle)
        do {
            try await withTaskCancellationHandler {
                try await withGracefulShutdownHandler {
                    try await asyncChannel.executeThenClose { inbound, outbound in
                        let responseWriter = HTTPServerBodyWriter(outbound: outbound)
                        var iterator = inbound.makeAsyncIterator()

                        // read first part, verify it is a head
                        guard let part = try await iterator.next() else { return }
                        guard case .head(var head) = part else {
                            throw HTTPChannelError.unexpectedHTTPPart(part)
                        }

                        while true {
                            // set to processing unless it is cancelled then exit
                            guard processingRequest.exchange(.processing) == .idle else { break }

                            let bodyStream = NIOAsyncChannelRequestBody(iterator: iterator)
                            let request = Request(head: head, body: .init(asyncSequence: bodyStream))
                            let response: Response = await self.responder(request, asyncChannel.channel)
                            do {
                                try await outbound.write(.head(response.head))
                                let tailHeaders = try await response.body.write(responseWriter)
                                try await outbound.write(.end(tailHeaders))
                            } catch {
                                throw error
                            }
                            if request.headers[.connection] == "close" {
                                return
                            }
                            // set to idle unless it is cancelled then exit
                            guard processingRequest.exchange(.idle) == .processing else { break }

                            // Flush current request
                            // read until we don't have a body part
                            var part: HTTPRequestPart?
                            while true {
                                part = try await iterator.next()
                                guard case .body = part else { break }
                            }
                            // if we have an end then read the next part
                            if case .end = part {
                                part = try await iterator.next()
                            }

                            // if part is nil break out of loop
                            guard let part else {
                                break
                            }

                            // part should be a head, if not throw error
                            guard case .head(let newHead) = part else { throw HTTPChannelError.unexpectedHTTPPart(part) }
                            head = newHead
                        }
                    }
                } onGracefulShutdown: {
                    // set to cancelled
                    if processingRequest.exchange(.cancelled) == .idle {
                        // only close the channel input if it is idle
                        asyncChannel.channel.close(mode: .input, promise: nil)
                    }
                }
            } onCancel: {
                asyncChannel.channel.close(mode: .input, promise: nil)
            }
        } catch {
            // we got here because we failed to either read or write to the channel
            logger.trace("Failed to read/write to Channel. Error: \(error)")
        }
    }
}

/// Writes ByteBuffers to AsyncChannel outbound writer
struct HTTPServerBodyWriter: Sendable, ResponseBodyWriter {
    typealias Out = HTTPResponsePart
    /// The components of a HTTP response from the view of a HTTP server.
    public typealias OutboundWriter = NIOAsyncChannelOutboundWriter<Out>

    let outbound: OutboundWriter

    func write(_ buffer: ByteBuffer) async throws {
        try await self.outbound.write(.body(buffer))
    }
}

extension NIOLockedValueBox {
    /// Exchange stored value for new value and return the old stored value
    func exchange(_ newValue: Value) -> Value {
        self.withLockedValue { value in
            let prevValue = value
            value = newValue
            return prevValue
        }
    }
}
