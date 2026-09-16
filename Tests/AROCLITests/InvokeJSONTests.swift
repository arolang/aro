// ============================================================
// InvokeJSONTests.swift
// AROCLI - `:invoke <name> <json>` (GitLab #578)
// ============================================================
//
// `MetaCommandRegistry.parseCommandLine` stripped `"` as shell-style quoting
// before dispatching, and `InvokeCommand` rejoined the surviving tokens with
// spaces. So correctly written JSON never survived the trip:
//
//     aro> :invoke Calculate Area {"width": 3, "height": 4}
//     Error: Invalid JSON input
//
// The parser had turned it into `{width: 3, height: 4}`. The only spelling
// that worked was one with the quotes escaped — which nobody types at a prompt.
//
// And even then the keys were bound as top-level variables, so a feature set
// written the ARO-0081 way (`Extract the <w> from the <input: width>.`) — the
// way a feature set in a *file* is written — failed at the prompt.

import Testing
import Foundation
@testable import AROCLI

@Suite("`:invoke` with JSON (GitLab #578)", .serialized)
struct InvokeJSONTests {

    // MARK: - The JSON argument

    @Test("Plain JSON parses, which is what a user types")
    func plainJSONParses() {
        let parsed = InvokeCommand.parseInputObject(#"{"width": 3, "height": 4}"#)
        #expect(parsed?["width"] as? Int == 3)
        #expect(parsed?["height"] as? Int == 4)
    }

    @Test("The backslash-escaped spelling still parses")
    func escapedJSONStillParses() {
        // Before the fix this was *the only* spelling that worked, so anyone
        // who learned the workaround has it in their notes. Fixing one broken
        // spelling must not break the other.
        let parsed = InvokeCommand.parseInputObject(#"{\"width\": 7}"#)
        #expect(parsed?["width"] as? Int == 7)
    }

    @Test("Nested objects and arrays parse")
    func nestedJSONParses() {
        let parsed = InvokeCommand.parseInputObject(#"{"user": {"id": 1}, "tags": ["a", "b"]}"#)
        #expect((parsed?["user"] as? [String: Any])?["id"] as? Int == 1)
        #expect((parsed?["tags"] as? [Any])?.count == 2)
    }

    @Test("A string value containing a brace or a space survives")
    func awkwardStringValues() {
        let parsed = InvokeCommand.parseInputObject(#"{"note": "a { b } c"}"#)
        #expect(parsed?["note"] as? String == "a { b } c")
    }

    @Test("Genuinely malformed JSON is still rejected")
    func malformedIsRejected() {
        #expect(InvokeCommand.parseInputObject("{not json at all") == nil)
        #expect(InvokeCommand.parseInputObject("") == nil)
    }

    @Test("A JSON array is not an input object")
    func arrayIsNotAnObject() {
        // `:invoke` binds named inputs, so the top level has to be an object.
        #expect(InvokeCommand.parseInputObject(#"["a", "b"]"#) == nil)
    }

    // MARK: - The tokenizer

    @Test("A brace-led argument reaches the command with its quotes intact")
    func tokenizerPassesJSONThrough() async {
        let session = REPLSession(suppressLogPrefix: true)
        let registry = MetaCommandRegistry.shared

        // `:fs` echoes nothing useful, so exercise the path that reports the
        // JSON back on failure: an unknown feature set with valid JSON must
        // complain about the feature set, not the JSON.
        let result = try? await registry.execute(
            input: #":invoke NoSuchFeatureSet {"width": 3}"#, session: session)

        guard case .error(let message)? = result else {
            return #expect(Bool(false), "expected an error, got \(String(describing: result))")
        }
        #expect(message.contains("not found"), "\(message)")
        #expect(!message.contains("Invalid JSON"), "\(message)")
    }

    @Test("A feature set name with spaces still parses alongside the JSON")
    func multiWordNameWithJSON() async {
        let session = REPLSession(suppressLogPrefix: true)
        let registry = MetaCommandRegistry.shared

        let result = try? await registry.execute(
            input: #":invoke Calculate Area {"width": 3}"#, session: session)

        guard case .error(let message)? = result else {
            return #expect(Bool(false), "expected an error, got \(String(describing: result))")
        }
        // The name was assembled from both words, not truncated at the first.
        #expect(message.contains("Calculate Area"), "\(message)")
    }

    // MARK: - The input shape

    @Test("An ARO-0081 feature set reads its arguments off `input`")
    func inputRecordIsBound() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)
        _ = await engine.executeCell("""
        (Calculate Area: Action) {
            Extract the <w> from the <input: width>.
            Extract the <h> from the <input: height>.
            Compute the <area> from <w> * <h>.
            Return an <OK: status> with <area>.
        }
        """)

        let result = try await session.invokeFeatureSet(
            named: "Calculate Area",
            input: ["width": 3, "height": 4]
        )
        guard case .value(let value) = result else {
            return #expect(Bool(false), "expected a value, got \(result)")
        }
        #expect("\(value)".contains("12"), "\(value)")
    }

    @Test("The top-level binds still work, so existing invocations keep running")
    func topLevelBindsStillWork() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)
        _ = await engine.executeCell("""
        (Double It: Action) {
            Compute the <d> from <width> * 2.
            Return an <OK: status> with <d>.
        }
        """)

        let result = try await session.invokeFeatureSet(named: "Double It", input: ["width": 5])
        guard case .value(let value) = result else {
            return #expect(Bool(false), "expected a value, got \(result)")
        }
        #expect("\(value)".contains("10"), "\(value)")
    }
}
