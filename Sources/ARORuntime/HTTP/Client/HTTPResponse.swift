// ============================================================
// HTTPResponse.swift
// ARO Runtime - Structured HTTP Request Result (ARO-0130)
// ============================================================

import Foundation

/// Structured result returned by `RequestAction`.
///
/// Wraps the HTTP response body together with the status code and response
/// headers so ARO code can access all three via `Extract`:
///
/// ```aro
/// Request the <response> from the <api-url>.
///
/// Extract the <body>          from the <response: body>.
/// Extract the <status>        from the <response: status>.
/// Extract the <content-type>  from the <response: headers: Content-Type>.
/// Extract the <remaining>     from the <response: headers: X-RateLimit-Remaining>.
///
/// (* Backwards compatible — unknown keys fall through to body *)
/// Extract the <users>         from the <response: users>.
/// ```
public struct AROHTTPResult: Sendable {
    /// The parsed response body.
    /// - JSON object responses are `[String: any Sendable]`
    /// - JSON array responses are `[any Sendable]`
    /// - Non-JSON responses are `String`
    public let body: any Sendable

    /// HTTP status code (e.g. 200, 404, 429)
    public let status: Int

    /// Response headers, keyed by header name (case-preserving)
    public let headers: [String: String]

    public init(body: any Sendable, status: Int, headers: [String: String]) {
        self.body = body
        self.status = status
        self.headers = headers
    }
}
