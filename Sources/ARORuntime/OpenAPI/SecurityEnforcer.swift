// ============================================================
// SecurityEnforcer.swift
// ARO Runtime - OpenAPI Security Scheme Enforcement
// ============================================================

#if !os(Windows)

import Foundation

/// Enforces OpenAPI security requirements on incoming requests.
///
/// Supports `apiKey` (header / query / cookie), `http` (bearer and basic),
/// and `oauth2` / `openIdConnect` (bearer token presence).
/// Scope validation is intentionally left to the feature set.
public struct SecurityEnforcer {

    /// Checks whether an operation's security requirements are satisfied.
    ///
    /// - Returns: `nil` when the request passes, or an `HTTPResponse` with
    ///   status 401 when authentication is required but missing.
    public static func enforce(
        operation: Operation,
        globalSecurity: [[String: [String]]]?,
        securitySchemes: [String: SecurityScheme]?,
        headers: [String: String],
        queryParameters: [String: String],
        resolvedSession: String? = nil
    ) -> HTTPResponse? {
        // operation.security == [] means explicitly public — no enforcement.
        let requirements: [[String: [String]]]
        if let opSecurity = operation.security {
            if opSecurity.isEmpty { return nil }
            requirements = opSecurity
        } else {
            requirements = globalSecurity ?? []
        }

        if requirements.isEmpty { return nil }

        // Requirements are OR'd — any one fully satisfied = OK.
        for requirement in requirements {
            if isSatisfied(requirement, schemes: securitySchemes, headers: headers,
                           queryParameters: queryParameters, resolvedSession: resolvedSession) {
                return nil
            }
        }

        return HTTPResponse(
            statusCode: 401,
            headers: ["Content-Type": "application/json", "WWW-Authenticate": "Bearer"],
            body: #"{"error":"Unauthorized","message":"Authentication required"}"#.data(using: .utf8)
        )
    }

    // MARK: - Private

    private static func isSatisfied(
        _ requirement: [String: [String]],
        schemes: [String: SecurityScheme]?,
        headers: [String: String],
        queryParameters: [String: String],
        resolvedSession: String?
    ) -> Bool {
        // All entries in a single requirement object are AND'd.
        for (schemeName, _) in requirement {
            guard let scheme = schemes?[schemeName] else { return false }
            if !schemePresent(scheme, headers: headers, queryParameters: queryParameters,
                              resolvedSession: resolvedSession) {
                return false
            }
        }
        return true
    }

    private static func schemePresent(
        _ scheme: SecurityScheme,
        headers: [String: String],
        queryParameters: [String: String],
        resolvedSession: String?
    ) -> Bool {
        switch scheme.type {
        case "apiKey":
            guard let name = scheme.name, let location = scheme.in else { return false }
            switch location {
            case "header":
                return headers.keys.contains(where: { $0.lowercased() == name.lowercased() })
            case "query":
                return queryParameters[name] != nil
            case "cookie":
                // A cookie scheme is the session scheme (ARO-0094 §8.1), so
                // what satisfies it is a session the runtime has actually
                // validated — not a cookie of that name being present.
                //
                // This branch used to be `cookieHeader.contains("\(name)=")`,
                // which passed on `Cookie: aro_session=` and on any value at
                // all, and even on `Cookie: not_aro_session=x`, since a
                // substring test does not know where a cookie name begins.
                // That was a gate on routes; once the same cookie selects
                // *whose data* a statement reads, it is a complete
                // authentication bypass (§8.3).
                let cookieHeader = headers.first(where: { $0.key.lowercased() == "cookie" })?.value ?? ""
                let cookies = SessionService.parseCookies(cookieHeader)
                guard let presented = cookies[name], !presented.isEmpty else { return false }
                return resolvedSession != nil
            default:
                return false
            }
        case "http":
            let authHeader = headers.first(where: { $0.key.lowercased() == "authorization" })?.value ?? ""
            switch scheme.scheme?.lowercased() {
            case "bearer":
                return authHeader.lowercased().hasPrefix("bearer ")
            case "basic":
                return authHeader.lowercased().hasPrefix("basic ")
            default:
                return false
            }
        case "oauth2", "openIdConnect":
            let authHeader = headers.first(where: { $0.key.lowercased() == "authorization" })?.value ?? ""
            return authHeader.lowercased().hasPrefix("bearer ")
        default:
            return false
        }
    }
}

#endif  // !os(Windows)
