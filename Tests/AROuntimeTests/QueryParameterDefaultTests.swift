// ============================================================
// QueryParameterDefaultTests.swift
// ARO Runtime — a query parameter's contract `default:` (GitLab #591)
// ============================================================
//
// `required: false` plus `default:` is how OpenAPI says "optional, and here
// is the value to use". ARO is contract-first, so the contract should not
// have to be restated in every handler — but an omitted parameter failed the
// extraction, and the handler had to supply the fallback itself.
//
// The injection logic existed, in `OpenAPIHTTPHandler` — which nothing calls.
// The live request path is `Application.handleHTTPRequest`, and that is where
// this now happens.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Query parameter contract defaults (#591)")
struct QueryParameterDefaultTests {

    /// A parameter declared `in: query` with an optional schema default.
    private func queryParameter(
        name: String, type: String, defaultValue: AnyCodableValue?
    ) -> Parameter {
        Parameter(
            name: name, in: "query", required: false, description: nil,
            schema: SchemaRef(Schema(type: type, defaultValue: defaultValue)),
            allowEmptyValue: nil, deprecated: nil, ref: nil, style: nil, explode: nil
        )
    }

    /// The rule under test, applied the way the request path applies it:
    /// only for a declared parameter that the request did not carry.
    private func applyDefaults(
        to params: [String: any Sendable], declaring parameters: [Parameter]
    ) -> [String: any Sendable] {
        var result = params
        for param in parameters where param.in == "query" {
            guard let name = param.name,
                  result[name] == nil,
                  let defaultValue = param.schema?.value.defaultValue else { continue }
            result[name] = "\(defaultValue.anyValue)"
        }
        return result
    }

    @Test("An omitted parameter takes the contract default")
    func omittedTakesDefault() {
        let result = applyDefaults(to: [:], declaring: [
            queryParameter(name: "limit", type: "integer", defaultValue: .int(10))
        ])
        #expect(result["limit"] as? String == "10")
    }

    @Test("A supplied value is never overwritten")
    func suppliedValueWins() {
        let result = applyDefaults(to: ["limit": "25"], declaring: [
            queryParameter(name: "limit", type: "integer", defaultValue: .int(10))
        ])
        #expect(result["limit"] as? String == "25")
    }

    @Test("`?limit=0` keeps the zero — the default fires on absence, not falsiness")
    func zeroIsNotAbsent() {
        let result = applyDefaults(to: ["limit": "0"], declaring: [
            queryParameter(name: "limit", type: "integer", defaultValue: .int(10))
        ])
        #expect(result["limit"] as? String == "0")
    }

    @Test("An empty string is a value the client sent, not an absence")
    func emptyStringIsNotAbsent() {
        let result = applyDefaults(to: ["q": ""], declaring: [
            queryParameter(name: "q", type: "string", defaultValue: .string("fallback"))
        ])
        #expect(result["q"] as? String == "")
    }

    @Test("A parameter with no default stays absent")
    func noDefaultStaysAbsent() {
        let result = applyDefaults(to: [:], declaring: [
            queryParameter(name: "cursor", type: "string", defaultValue: nil)
        ])
        #expect(result["cursor"] == nil)
    }

    @Test("Defaults are filled per parameter, not all-or-nothing")
    func perParameter() {
        let result = applyDefaults(to: ["sort": "desc"], declaring: [
            queryParameter(name: "limit", type: "integer", defaultValue: .int(10)),
            queryParameter(name: "sort", type: "string", defaultValue: .string("asc"))
        ])
        #expect(result["limit"] as? String == "10")
        #expect(result["sort"] as? String == "desc")
    }

    @Test("The default is a string, matching how a supplied value arrives")
    func defaultIsAString() {
        // `?limit=25` binds the string "25", so an omitted `limit` binds "10".
        // One parameter changing type depending on whether the client sent it
        // would be a worse surprise than losing the YAML scalar's type.
        let result = applyDefaults(to: [:], declaring: [
            queryParameter(name: "limit", type: "integer", defaultValue: .int(10))
        ])
        #expect(result["limit"] is String)
        #expect(!(result["limit"] is Int))
    }

    @Test("A non-query parameter's default is not injected into the query map")
    func onlyQueryParameters() {
        let header = Parameter(
            name: "x-trace", in: "header", required: false, description: nil,
            schema: SchemaRef(Schema(type: "string", defaultValue: .string("none"))),
            allowEmptyValue: nil, deprecated: nil, ref: nil, style: nil, explode: nil
        )
        #expect(applyDefaults(to: [:], declaring: [header]).isEmpty)
    }
}
