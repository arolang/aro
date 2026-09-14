// ============================================================
// QualifierValueKeyTests.swift
// ARORuntimeTests - `{"value": …}` from a qualifier (GitLab #554)
// ============================================================
//
// `QualifierOutput` decoded only `result` and `error`, so anything else was
// "Plugin returned neither result nor error". The Rust SDK's constructor named
// after this very case builds the other key — `Output::value(v)` is
// `{"value": v}` (`output.rs:34`) — and its README's qualifier example is
// `Ok(Output::value(json!(value)))`. `ffi::wrap_qualifier` passes the `Output`
// through verbatim, so a plugin written from the SDK's own README failed at run
// time.

import Testing
import Foundation
@testable import ARORuntime

@Suite("A qualifier may answer under `value` (GitLab #554)")
struct QualifierValueKeyTests {

    private func decode(_ json: String) throws -> any Sendable {
        try PluginInfoParser.decodeQualifierResult(
            from: Data(json.utf8),
            qualifier: "shout",
            decoder: JSONDecoder()
        )
    }

    // MARK: - Both keys carry a result

    @Test("`value` is read as the result")
    func valueKeyDecodes() throws {
        #expect(try decode(#"{"value": "HELLO"}"#) as? String == "HELLO")
        #expect(try decode(#"{"value": [1, 2, 3]}"#) as? [Int] == [1, 2, 3])
    }

    @Test("`result` still is, and is unchanged")
    func resultKeyStillDecodes() throws {
        #expect(try decode(#"{"result": "HELLO"}"#) as? String == "HELLO")
    }

    @Test("`result` wins when a plugin sends both")
    func resultWinsOverValue() throws {
        // Not a shape any SDK produces; pinned so the precedence is not
        // accidental. `result` is the documented key, so it decides.
        #expect(try decode(#"{"result": "FROM-RESULT", "value": "FROM-VALUE"}"#) as? String
                == "FROM-RESULT")
    }

    // MARK: - What the alias must NOT do

    @Test("A result that is itself an object with a `value` field is untouched")
    func nestedValueIsNotUnwrapped() throws {
        // The alias is read at the top level only. A qualifier whose result
        // genuinely is `{"value": …}` sends it under `result` and keeps it —
        // otherwise this fix would create the #551 mis-binding it is unrelated to.
        let decoded = try decode(#"{"result": {"value": "HELLO"}}"#)
        #expect(decoded as? String == nil)
        #expect((decoded as? [String: any Sendable])?["value"] as? String == "HELLO")
    }

    // MARK: - Errors and the empty envelope

    @Test("An error still takes precedence over either key")
    func errorStillWins() {
        #expect(throws: QualifierError.self) {
            _ = try decode(#"{"error": "bad input", "value": "HELLO"}"#)
        }
    }

    @Test("Neither key is still the same failure")
    func neitherKeyStillThrows() {
        #expect(throws: QualifierError.self) {
            _ = try decode(#"{"other": "HELLO"}"#)
        }
    }

    @Test("isSuccess agrees with the decoder about both keys")
    func isSuccessAgrees() throws {
        let decoder = JSONDecoder()
        func output(_ json: String) throws -> QualifierOutput {
            try decoder.decode(QualifierOutput.self, from: Data(json.utf8))
        }
        #expect(try output(#"{"result": "HI"}"#).isSuccess)
        #expect(try output(#"{"value": "HI"}"#).isSuccess)
        #expect(try !output(#"{"error": "no"}"#).isSuccess)
        #expect(try !output(#"{}"#).isSuccess)
    }
}
