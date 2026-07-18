// ============================================================
// OpenAPIRuntimeExpression.swift
// ARO Runtime - OpenAPI Runtime Expression Evaluation (ARO-0187)
// ============================================================

import Foundation

/// Evaluates the subset of OpenAPI *runtime expressions* that ARO supports for
/// resolving Callback Object URLs and out-of-band request values.
///
/// OpenAPI defines a small expression language (see
/// <https://spec.openapis.org/oas/v3.1.0#runtime-expressions>) used, among
/// other places, as the *keys* of a Callback Object to compute the URL the
/// server should call back. The full grammar is intentionally **out of scope**
/// for ARO-0187; this evaluator implements the common, high-value subset:
///
/// | Expression                    | Resolves to                                   |
/// |-------------------------------|-----------------------------------------------|
/// | `$url`                        | the request URL (path + query)                |
/// | `$method`                     | the request HTTP method                       |
/// | `$request.query.<name>`       | a query parameter value                       |
/// | `$request.header.<name>`      | a request header value (case-insensitive)     |
/// | `$request.path.<name>`        | a path parameter value                        |
/// | `$request.body#/<json-ptr>`   | a JSON-pointer lookup into the request body   |
/// | `$request.body`               | the whole request body (as a string)          |
///
/// Callback keys embed an expression inside a template, e.g.
/// `{$request.body#/callbackUrl}`, and may surround it with literal text
/// (`https://{$request.header.host}/cb`). ``resolveTemplate(_:context:)``
/// substitutes every `{…}` occurrence.
///
/// Anything outside the table above (e.g. `$response.*`, `$request.body#/…`
/// with array indices beyond simple keys, `$statusCode`) is reported as
/// unsupported rather than silently producing an empty string, so callers can
/// surface a clear diagnostic.
public enum OpenAPIRuntimeExpression {

    /// The request-side context an expression is evaluated against.
    ///
    /// This deliberately mirrors only what the supported expression subset can
    /// read, keeping it trivial to construct in tests without a live HTTP
    /// server.
    public struct Context: Sendable {
        public let method: String
        /// The request URL as seen by the server (path, optionally with query).
        public let url: String
        public let headers: [String: String]
        public let queryParameters: [String: String]
        public let pathParameters: [String: String]
        /// The raw request body, if any.
        public let body: Data?

        public init(
            method: String,
            url: String,
            headers: [String: String] = [:],
            queryParameters: [String: String] = [:],
            pathParameters: [String: String] = [:],
            body: Data? = nil
        ) {
            self.method = method
            self.url = url
            self.headers = headers
            self.queryParameters = queryParameters
            self.pathParameters = pathParameters
            self.body = body
        }
    }

    /// Errors raised while evaluating a runtime expression.
    public enum EvaluationError: Error, Equatable, Sendable, CustomStringConvertible {
        /// The expression is syntactically valid but not part of the supported subset.
        case unsupported(String)
        /// The expression is supported but the referenced value is absent.
        case notFound(String)
        /// The expression is malformed (e.g. empty, or a bad JSON pointer).
        case malformed(String)

        public var description: String {
            switch self {
            case .unsupported(let e): return "Unsupported OpenAPI runtime expression: \(e)"
            case .notFound(let e): return "OpenAPI runtime expression resolved to no value: \(e)"
            case .malformed(let e): return "Malformed OpenAPI runtime expression: \(e)"
            }
        }
    }

    // MARK: - Template resolution

    /// Resolve a Callback key / URL template by substituting every `{…}`
    /// runtime expression against `context`.
    ///
    /// Literal text outside braces is preserved. A template with no braces is
    /// returned unchanged. Callback keys are frequently a bare expression
    /// (`{$request.body#/callbackUrl}`); those resolve to exactly the referenced
    /// value.
    public static func resolveTemplate(_ template: String, context: Context) throws -> String {
        var result = ""
        var remainder = Substring(template)

        while let open = remainder.firstIndex(of: "{") {
            // Emit the literal text before the '{'.
            result += remainder[remainder.startIndex..<open]

            let afterOpen = remainder.index(after: open)
            guard let close = remainder[afterOpen...].firstIndex(of: "}") else {
                throw EvaluationError.malformed("unbalanced '{' in template '\(template)'")
            }

            let exprText = String(remainder[afterOpen..<close])
            result += try evaluate(exprText, context: context)

            remainder = remainder[remainder.index(after: close)...]
        }

        result += remainder
        return result
    }

    // MARK: - Single expression evaluation

    /// Evaluate a single runtime expression (no surrounding braces) and return
    /// its string value.
    public static func evaluate(_ expression: String, context: Context) throws -> String {
        let expr = expression.trimmingCharacters(in: .whitespaces)
        guard expr.hasPrefix("$") else {
            throw EvaluationError.malformed("expression must start with '$': '\(expression)'")
        }

        switch expr {
        case "$url":
            return context.url
        case "$method":
            return context.method
        case "$request.body":
            guard let body = context.body, let str = String(data: body, encoding: .utf8) else {
                throw EvaluationError.notFound(expr)
            }
            return str
        default:
            break
        }

        // $request.body#/<json-pointer>
        if let ptrRange = expr.range(of: "$request.body#") {
            let pointer = String(expr[ptrRange.upperBound...])
            return try evaluateBodyPointer(pointer, context: context, original: expr)
        }

        // $request.query.<name>
        if let name = suffix(of: expr, afterPrefix: "$request.query.") {
            guard let value = context.queryParameters[name] else {
                throw EvaluationError.notFound(expr)
            }
            return value
        }

        // $request.header.<name>  (header names are case-insensitive)
        if let name = suffix(of: expr, afterPrefix: "$request.header.") {
            let lower = name.lowercased()
            guard let value = context.headers.first(where: { $0.key.lowercased() == lower })?.value else {
                throw EvaluationError.notFound(expr)
            }
            return value
        }

        // $request.path.<name>
        if let name = suffix(of: expr, afterPrefix: "$request.path.") {
            guard let value = context.pathParameters[name] else {
                throw EvaluationError.notFound(expr)
            }
            return value
        }

        throw EvaluationError.unsupported(expr)
    }

    // MARK: - Helpers

    private static func suffix(of expr: String, afterPrefix prefix: String) -> String? {
        guard expr.hasPrefix(prefix) else { return nil }
        let name = String(expr.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }

    /// Resolve a JSON pointer (RFC 6901) into the request body.
    /// Supports object-key and array-index traversal of scalar leaves.
    private static func evaluateBodyPointer(_ pointer: String, context: Context, original: String) throws -> String {
        guard let body = context.body else {
            throw EvaluationError.notFound(original)
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        } catch {
            throw EvaluationError.malformed("request body is not valid JSON for '\(original)'")
        }

        // An empty pointer ("") references the whole document.
        guard !pointer.isEmpty else {
            return stringify(json) ?? { () -> String in "" }()
        }
        guard pointer.hasPrefix("/") else {
            throw EvaluationError.malformed("JSON pointer must start with '/': '\(pointer)'")
        }

        // RFC 6901 token unescaping: ~1 -> '/', ~0 -> '~'.
        let tokens = pointer.dropFirst().components(separatedBy: "/").map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }

        var current: Any = json
        for token in tokens {
            if let dict = current as? [String: Any] {
                guard let next = dict[token] else { throw EvaluationError.notFound(original) }
                current = next
            } else if let array = current as? [Any] {
                guard let idx = Int(token), idx >= 0, idx < array.count else {
                    throw EvaluationError.notFound(original)
                }
                current = array[idx]
            } else {
                throw EvaluationError.notFound(original)
            }
        }

        guard let value = stringify(current) else {
            throw EvaluationError.notFound(original)
        }
        return value
    }

    /// Convert a JSON leaf into its string form. Objects/arrays are re-serialized.
    private static func stringify(_ value: Any) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            // JSON booleans bridge to NSNumber backed by CFBoolean. Detect them
            // explicitly so integer 1/0 are not misread as true/false (the
            // classic `NSNumber(1) as? Bool == true` Swift pitfall).
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            // Distinguish integers from doubles for clean URLs.
            if CFNumberIsFloatType(n) {
                return "\(n.doubleValue)"
            }
            return "\(n.intValue)"
        case is NSNull: return ""
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return nil
        }
    }
}
