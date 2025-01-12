//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2023 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes
import NIOCore

/// Middleware implementing Cross-Origin Resource Sharing (CORS) headers.
///
/// If request has "origin" header then generate CORS headers. If method is OPTIONS
/// then return an empty body with all the standard CORS headers otherwise send
/// request onto the next handler and when you receive the response add a
/// "access-control-allow-origin" header
public struct CORSMiddleware<Context: BaseRequestContext>: RouterMiddleware {
    /// Defines what origins are allowed
    public enum AllowOrigin: Sendable {
        case none
        case all
        case originBased
        case custom(String)

        func value(for request: Request) -> String? {
            switch self {
            case .none:
                return nil
            case .all:
                return "*"
            case .originBased:
                let origin = request.headers[.origin]
                if origin == "null" { return nil }
                return origin
            case .custom(let value):
                return value
            }
        }
    }

    /// What origins are allowed, header `Access-Control-Allow-Origin`
    let allowOrigin: AllowOrigin
    /// What headers are allowed, header `Access-Control-Allow-Headers`
    let allowHeaders: String
    /// What methods are allowed, header `Access-Control-Allow-Methods`
    let allowMethods: String
    /// Are requests with cookies or an "Authorization" header allowed, header `Access-Control-Allow-Credentials`
    let allowCredentials: Bool
    /// What headers can be exposed back to the browser, header `Access-Control-Expose-Headers`
    let exposedHeaders: String?
    /// how long the results of a pre-flight request can be cached, header `Access-Control-Max-Age`
    let maxAge: String?

    /// Initialize CORS middleware
    ///
    /// - Parameters:
    ///   - allowOrigin: allow origin enum
    ///   - allowHeaders: array of headers that are allowed
    ///   - allowMethods: array of methods that are allowed
    ///   - allowCredentials: are credentials alloed
    ///   - exposedHeaders: array of headers that can be exposed back to the browser
    ///   - maxAge: how long the results of a pre-flight request can be cached
    public init(
        allowOrigin: AllowOrigin = .originBased,
        allowHeaders: [HTTPField.Name] = [.accept, .authorization, .contentType, .origin],
        allowMethods: [HTTPRequest.Method] = [.get, .post, .head, .options],
        allowCredentials: Bool = false,
        exposedHeaders: [String]? = nil,
        maxAge: TimeAmount? = nil
    ) {
        self.allowOrigin = allowOrigin
        self.allowHeaders = allowHeaders.map(\.canonicalName).joined(separator: ", ")
        self.allowMethods = allowMethods.map(\.rawValue).joined(separator: ", ")
        self.allowCredentials = allowCredentials
        self.exposedHeaders = exposedHeaders?.joined(separator: ", ")
        self.maxAge = maxAge.map { String(describing: $0.nanoseconds / 1_000_000_000) }
    }

    /// apply CORS middleware
    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        // if no origin header then don't apply CORS
        guard request.headers.contains(.origin) else {
            return try await next(request, context)
        }

        if request.method == .options {
            // if request is OPTIONS then return CORS headers and skip the rest of the middleware chain
            var headers: HTTPFields = [
                .accessControlAllowHeaders: self.allowHeaders,
                .accessControlAllowMethods: self.allowMethods,
            ]
            if let allowOrigin = allowOrigin.value(for: request) {
                headers[.accessControlAllowOrigin] = allowOrigin
            }
            if self.allowCredentials {
                headers[.accessControlAllowCredentials] = "true"
            }
            if let maxAge = self.maxAge {
                headers[.accessControlMaxAge] = maxAge
            }
            if let exposedHeaders = self.exposedHeaders {
                headers[.accessControlExposeHeaders] = exposedHeaders
            }
            if case .originBased = self.allowOrigin {
                headers[.vary] = "Origin"
            }

            return Response(status: .noContent, headers: headers, body: .init())
        } else {
            // if not OPTIONS then run rest of middleware chain and add origin value at the end
            do {
                var response = try await next(request, context)
                response.headers[.accessControlAllowOrigin] = self.allowOrigin.value(for: request)
                if self.allowCredentials {
                    response.headers[.accessControlAllowCredentials] = "true"
                }
                if case .originBased = self.allowOrigin {
                    response.headers[.vary] = "Origin"
                }
                return response
            } catch {
                // If next throws an error add headers to error
                var additionalHeaders = HTTPFields()
                additionalHeaders[.accessControlAllowOrigin] = self.allowOrigin.value(for: request)
                if self.allowCredentials {
                    additionalHeaders[.accessControlAllowCredentials] = "true"
                }
                if case .originBased = self.allowOrigin {
                    additionalHeaders[.vary] = "Origin"
                }
                throw EditedHTTPError(
                    originalError: error,
                    additionalHeaders: additionalHeaders,
                    context: context
                )
            }
        }
    }
}
