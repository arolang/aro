// ============================================================
// ActionFailureMessageTests.swift
// ARO Runtime — what an action failure says across the C bridge
// ============================================================
//
// `ActionRunner` hands a failed action's message to the compiled binary as a
// plain string. It built that string with `String(describing:)`, which on an
// error *struct* prints the memberwise initialiser — so a compiled server
// answered a rejected state transition with
//
//     AcceptStateError(expectedFrom: "draft", expectedTo: "cancelled", …)
//
// over HTTP. The interpreter never did, so the two modes disagreed about what
// an error looks like, and only the compiled one leaked Swift internals to an
// API consumer.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Action failure messages")
struct ActionFailureMessageTests {

    /// Not `LocalizedError` — the fallback still has to say something useful.
    private struct BareError: Error {
        let detail: String
    }

    private struct SpokenError: Error, LocalizedError {
        var errorDescription: String? { "the thing went wrong" }
    }

    private struct EmptyMessageError: Error, LocalizedError {
        var errorDescription: String? { "" }
    }

    @Test("A LocalizedError contributes its own message")
    func localizedErrorUsesItsDescription() {
        #expect(ActionRunner.failureMessage(for: SpokenError()) == "the thing went wrong")
    }

    @Test("AcceptStateError reads as a sentence, not as a struct literal")
    func acceptStateErrorIsReadable() {
        let message = ActionRunner.failureMessage(for: AcceptStateError(
            expectedFrom: "draft", expectedTo: "cancelled",
            actualState: "placed", objectName: "order", fieldName: "status"
        ))
        #expect(message == #"Cannot accept state draft->cancelled on order: status. Current state is "placed"."#)
        // The specific regression: no memberwise dump.
        #expect(!message.contains("AcceptStateError("))
        #expect(!message.contains("expectedFrom:"))
    }

    @Test("An ActionError keeps the message it already formats")
    func actionErrorKeepsItsMessage() {
        let message = ActionRunner.failureMessage(for: ActionError.undefinedVariable("total"))
        #expect(message.contains("total"))
        #expect(!message.contains("undefinedVariable("))
    }

    @Test("An error with no message of its own falls back, not to Foundation's placeholder")
    func bareErrorFallsBackToDescribing() {
        // `localizedDescription` would answer "The operation couldn't be
        // completed. (… error 1.)" here, which says strictly less than the
        // struct dump. So the fallback is deliberate, not an oversight.
        let message = ActionRunner.failureMessage(for: BareError(detail: "port 8081 in use"))
        #expect(message.contains("port 8081 in use"))
        #expect(!message.contains("couldn’t be completed"))
    }

    @Test("An empty errorDescription falls back too")
    func emptyMessageFallsBack() {
        let message = ActionRunner.failureMessage(for: EmptyMessageError())
        #expect(!message.isEmpty)
        #expect(message.contains("EmptyMessageError"))
    }
}
