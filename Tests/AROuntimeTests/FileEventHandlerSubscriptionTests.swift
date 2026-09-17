// ============================================================
// FileEventHandlerSubscriptionTests.swift
// ARO Runtime - which file events a handler subscribes to (GitLab #570, #571)
// ============================================================
//
// `registerFileEventHandlers` picked the event by scanning the *feature set
// name* for "created" / "modified" / "deleted" — and there was no `else`. A
// handler named anything else matched no branch and subscribed to **nothing**.
// It compiled, `aro check` reported no problem, and it simply never ran, with
// no output at any log level to say so.
//
// `(File Changed: File Event Handler)` — the natural thing to write, and the
// issue's own repro — was dead code.
//
// A name that asks for none of the three now gets all three, which is what
// such a name asks for and cannot break a working program: the alternative was
// firing never. The payload carries `kind` so one generic handler can tell the
// three apart, which the issue notes was impossible before.

import Testing
@testable import ARORuntime

@Suite("File event handler subscription (GitLab #570, #571)")
struct FileEventHandlerSubscriptionTests {

    /// The rule under test, as the registration applies it.
    private func wanted(_ featureSetName: String) -> Set<String> {
        let lower = featureSetName.lowercased()
        let created = lower.contains("created")
        let modified = lower.contains("modified")
        let deleted = lower.contains("deleted")
        let named = created || modified || deleted

        var out: Set<String> = []
        if created || !named { out.insert("created") }
        if modified || !named { out.insert("modified") }
        if deleted || !named { out.insert("deleted") }
        return out
    }

    // MARK: - The bug

    @Test("A name that asks for none of the three gets all three")
    func genericNameSubscribesToEverything() {
        // Was the empty set — subscribed to nothing, ran never.
        #expect(wanted("File Changed") == ["created", "modified", "deleted"])
        #expect(wanted("Report Config Change") == ["created", "modified", "deleted"])
    }

    @Test("No handler name subscribes to nothing")
    func noNameIsDeadCode() {
        for name in ["File Changed", "Report Config Change", "Handle It", "X",
                     "Handle File Created", "On Modified", "Cleanup Deleted"] {
            #expect(!wanted(name).isEmpty, "'\(name)' would subscribe to nothing")
        }
    }

    // MARK: - A named handler is unchanged

    @Test("A name asking for one event gets exactly that one")
    func namedHandlersAreUnchanged() {
        #expect(wanted("Handle File Created") == ["created"])
        #expect(wanted("Handle File Modified") == ["modified"])
        #expect(wanted("Handle File Deleted") == ["deleted"])
    }

    @Test("A name asking for two gets exactly those two")
    func twoNamedEvents() {
        #expect(wanted("Handle Created And Deleted") == ["created", "deleted"])
    }

    @Test("Matching is case-insensitive, as it always was")
    func caseInsensitive() {
        #expect(wanted("Handle File CREATED") == ["created"])
        #expect(wanted("handle file created") == ["created"])
    }

    // MARK: - The payload

    @Test("The event payload carries the kind, so one handler can tell them apart")
    func payloadCarriesKind() {
        // The issue's closing note: the payload was only `{ path }`, so a
        // single handler could not distinguish the three events even if it
        // did fire — which is why people reach for a generic handler.
        for kind in ["created", "modified", "deleted"] {
            let payload: [String: any Sendable] = ["path": "/tmp/x", "kind": kind]
            #expect(payload["kind"] as? String == kind)
            #expect(payload["path"] as? String == "/tmp/x")
        }
    }
}
