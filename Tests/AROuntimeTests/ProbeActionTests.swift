// ============================================================
// ProbeActionTests.swift
// ARO Runtime - Probe action (reachability checks, issue #373)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Probe Action")
struct ProbeActionTests {

    private func descriptors(
        objectBase: String,
        preposition: Preposition = .from
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "reachability", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: [], span: span)
        return (result, object)
    }

    @Test("registers the probe verb with REQUEST role")
    func verbAndRole() {
        #expect(ProbeAction.verbs.contains("probe"))
        #expect(ProbeAction.role == .request)
        #expect(ProbeAction.validPrepositions.contains(.from))
    }

    @Test("defaults to an aggressive 2s timeout")
    func defaultTimeout() {
        #expect(ProbeAction.defaultTimeout == 2.0)
    }

    @Test("malformed URL still halts — programming error, not unreachability")
    func malformedURLThrows() async throws {
        let action = ProbeAction()
        let context = RuntimeContext(featureSetName: "Test")
        let (result, object) = descriptors(objectBase: "not-a-url")

        await #expect(throws: ActionError.self) {
            _ = try await action.execute(result: result, object: object, context: context)
        }
    }

    @Test("connection refused yields reachable: false instead of throwing")
    func connectionRefusedIsAnAnswer() async throws {
        let action = ProbeAction()
        let context = RuntimeContext(featureSetName: "Test")
        // Port 1 on loopback: connect is refused immediately — no
        // DNS, no network dependency, deterministic offline.
        let (result, object) = descriptors(objectBase: "http://127.0.0.1:1")

        let value = try await action.execute(result: result, object: object, context: context)
        let envelope = try #require(value as? [String: any Sendable])
        #expect(envelope["reachable"] as? Bool == false)
        #expect(envelope["target"] as? String == "http://127.0.0.1:1")
        #expect(envelope["reason"] as? String != nil)
        // status/latency are absent when unreachable — nil, not 0.
        #expect(envelope["status"] == nil)
        #expect(envelope["latency"] == nil)
    }

    @Test("unresolvable host yields reachable: false instead of throwing")
    func nxdomainIsAnAnswer() async throws {
        let action = ProbeAction()
        let context = RuntimeContext(featureSetName: "Test")
        // .invalid is reserved (RFC 2606) — guaranteed NXDOMAIN.
        let (result, object) = descriptors(
            objectBase: "http://habichmirnurausgedacht.invalid")

        let value = try await action.execute(result: result, object: object, context: context)
        let envelope = try #require(value as? [String: any Sendable])
        #expect(envelope["reachable"] as? Bool == false)
        #expect(envelope["status"] == nil)
    }

    @Test("resolves the target from a bound variable")
    func resolvesBoundVariable() async throws {
        let action = ProbeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("target", value: "http://127.0.0.1:1")
        let (result, object) = descriptors(objectBase: "target")

        let value = try await action.execute(result: result, object: object, context: context)
        let envelope = try #require(value as? [String: any Sendable])
        #expect(envelope["target"] as? String == "http://127.0.0.1:1")
        #expect(envelope["reachable"] as? Bool == false)
    }
}

// MARK: - Integration Tests (require network)

#if canImport(Network)
@Suite("Probe Action Integration", .serialized)
struct ProbeActionIntegrationTests {

    @Test("reachable target yields status and latency")
    func reachableTarget() async throws {
        let action = ProbeAction()
        let context = RuntimeContext(featureSetName: "Test")
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "reachability", specifiers: [], span: span)
        let object = ObjectDescriptor(
            preposition: .from,
            base: "https://jsonplaceholder.typicode.com/todos/1",
            specifiers: [],
            span: span
        )

        let value = try await action.execute(result: result, object: object, context: context)
        let envelope = try #require(value as? [String: any Sendable])
        #expect(envelope["reachable"] as? Bool == true)
        let status = try #require(envelope["status"] as? Int)
        // Any HTTP status counts as reachable; this endpoint
        // normally answers 200.
        #expect((100...599).contains(status))
        let latency = try #require(envelope["latency"] as? Double)
        #expect(latency > 0)
        #expect(envelope["reason"] == nil)
    }
}
#endif
