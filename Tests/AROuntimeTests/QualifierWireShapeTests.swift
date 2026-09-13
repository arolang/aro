// ============================================================
// QualifierWireShapeTests.swift
// ARORuntimeTests - what a qualifier must put on the wire (GitLab #551)
// ============================================================
//
// The wire shape for a qualifier result is exactly `{"result": <the value>}`.
// `decodeQualifierResult` returns `result.value` verbatim, and neither
// `QualifierRegistry` nor `ComputeAction` unwraps anything further — so a
// handler that returns a dict gets that dict bound as the value.
//
// The Python SDK's `export_abi` wraps a handler's return in `{"result": ...}`
// on its own, so a handler returning `{"result": x}` shipped
// `{"result": {"result": x}}` and `Compute the <sorted: Collections.sort> from
// <numbers>.` bound the dict `{"result": [1, 2, 3]}` rather than the list.
// `Examples/QualifierPluginPython` did exactly that in all six of its
// qualifiers. These tests pin the contract the example now meets.

import Testing
import Foundation
@testable import ARORuntime

@Suite("Qualifier result wire shape (GitLab #551)")
struct QualifierWireShapeTests {

    private func decode(_ json: String) throws -> any Sendable {
        try PluginInfoParser.decodeQualifierResult(
            from: Data(json.utf8),
            qualifier: "sort",
            decoder: JSONDecoder()
        )
    }

    // MARK: - The correct shape

    @Test("A bare value under `result` decodes to that value")
    func bareValueDecodes() throws {
        #expect(try decode(#"{"result": [1, 2, 3]}"#) as? [Int] == [1, 2, 3])
        #expect(try decode(#"{"result": "HI"}"#) as? String == "HI")
        #expect(try decode(#"{"result": 150}"#) as? Int == 150)
    }

    // MARK: - The double-wrapped shape is visibly wrong

    @Test("A wrapped value decodes to the wrapper, not the value")
    func doubleWrappedYieldsTheDict() throws {
        // This is the bug, stated as an assertion: nothing downstream unwraps,
        // so the dict itself is what a Compute would bind.
        let decoded = try decode(#"{"result": {"result": [1, 2, 3]}}"#)
        let dict = decoded as? [String: any Sendable]
        #expect(dict != nil, "expected the wrapper dict to survive as the value")
        #expect(dict?["result"] as? [Int] == [1, 2, 3])
    }

    @Test("`value` as the inner key is no better than `result`")
    func valueKeyIsAlsoJustADict() throws {
        // The SDK README and its `ok()` helper both produce this one.
        let decoded = try decode(#"{"result": {"value": "HI"}}"#)
        #expect(decoded as? String == nil, "a wrapped value must not decode as the value")
        #expect((decoded as? [String: any Sendable])?["value"] as? String == "HI")
    }

    // MARK: - Errors

    @Test("An error is reported as a failure, not bound as a value")
    func errorIsThrown() {
        #expect(throws: QualifierError.self) {
            _ = try decode(#"{"error": "sort requires a list"}"#)
        }
    }

    @Test("A handler that returns its error instead of raising binds it as a value")
    func returnedErrorBecomesAValue() throws {
        // `export_abi` only produces `{"error": …}` from an *exception*; a
        // returned `{"error": …}` is wrapped as a value like any other, so the
        // failure would be silently bound. That is why the shipped example
        // raises rather than returning an error dict.
        let decoded = try decode(#"{"result": {"error": "sort requires a list"}}"#)
        #expect((decoded as? [String: any Sendable])?["error"] as? String
                == "sort requires a list")
    }

    @Test("Neither key is a failure with a message that says so")
    func neitherKeyThrows() {
        #expect(throws: QualifierError.self) {
            _ = try decode(#"{"value": "HI"}"#)
        }
    }
}
