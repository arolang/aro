// ============================================================
// HTTPClient+Callback.swift
// ARO Runtime - AROHTTPClient as an OpenAPI callback invoker (ARO-0187)
// ============================================================

#if !os(Windows)

import Foundation

/// Adapts ``AROHTTPClient`` to the ``CallbackHTTPInvoker`` seam so
/// ``OpenAPICallbackDispatcher`` can fire outbound OpenAPI callbacks over the
/// real network using the same client ARO uses for all other outgoing HTTP.
///
/// The method string coming from the Callback Object's Path Item is mapped onto
/// the client's typed verbs. GET/DELETE ignore the body per HTTP semantics; any
/// verb ARO's client does not model directly (HEAD/OPTIONS/TRACE) falls back to
/// a bodyless GET, which is sufficient for the callback "ping" use case.
extension AROHTTPClient: CallbackHTTPInvoker {
    public func send(
        method: String,
        url: String,
        body: Data?,
        headers: [String: String]
    ) async throws -> Int {
        var headers = headers
        // Default a JSON content type when we are sending a body and the caller
        // did not specify one, matching how callback payloads are typically
        // forwarded.
        if body != nil, !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
            headers["Content-Type"] = "application/json"
        }

        let response: HTTPClientResponse
        switch method.uppercased() {
        case "POST":
            response = try await post(url: url, headers: headers, body: body)
        case "PUT":
            response = try await put(url: url, headers: headers, body: body)
        case "PATCH":
            response = try await patch(url: url, headers: headers, body: body)
        case "DELETE":
            response = try await delete(url: url, headers: headers)
        case "GET":
            response = try await get(url: url, headers: headers)
        default:
            // HEAD/OPTIONS/TRACE and anything unmodeled: treat as a bodyless GET ping.
            response = try await get(url: url, headers: headers)
        }
        return response.statusCode
    }
}

#endif  // !os(Windows)
