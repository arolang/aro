// ============================================================
// BranchEditReplayTests.swift
// Issue #447 — time-travel "branch & edit" trace replay engine.
// ============================================================
//
// Validates the runtime core behind SOLARO's forked time-travel: seeding a
// feature set with a recorded (and mutated) symbol state and re-running the
// statements downstream produces a trace whose values reflect the mutation —
// both when replaying the whole feature set and when re-entering mid-stream.

import XCTest
@testable import ARORuntime

final class BranchEditReplayTests: XCTestCase {

    private let source = """
    (Doubler: Test) {
        Compute the <doubled> from <base> * 2.
        Compute the <plus> from <doubled> + 5.
        Return an <OK: status> with <plus>.
    }
    """

    /// Most recent preview of a symbol across a fork's steps (steps snapshot
    /// state *before* each statement, so the last occurrence is the freshest).
    private func latest(_ fork: TraceReplayEngine.Fork, _ name: String) -> String? {
        for step in fork.steps.reversed() {
            if let s = step.symbols.first(where: { $0.name == name }) {
                return s.valuePreview
            }
        }
        return nil
    }

    /// Replaying the whole feature set with a mutated seed input propagates the
    /// mutation through every downstream Compute.
    func testReplayFromStartPropagatesMutatedInput() async throws {
        let fork10 = try await TraceReplayEngine.replay(
            source: source, featureSetName: "Doubler", startIndex: 0,
            seeds: ["base": 10]
        )
        XCTAssertNil(fork10.error, "replay should not error: \(fork10.error ?? "")")
        XCTAssertEqual(latest(fork10, "doubled"), "20")
        XCTAssertEqual(latest(fork10, "plus"), "25")

        // Same feature set, one value branched — the fork diverges.
        let fork100 = try await TraceReplayEngine.replay(
            source: source, featureSetName: "Doubler", startIndex: 0,
            seeds: ["base": 100]
        )
        XCTAssertNil(fork100.error)
        XCTAssertEqual(latest(fork100, "doubled"), "200")
        XCTAssertEqual(latest(fork100, "plus"), "205")
    }

    /// Re-entering mid-feature-set (from statement index 1) uses the seeded
    /// state for the already-executed prefix and only re-runs downstream — the
    /// defining behaviour of "branch & edit at a tick".
    func testReplayFromMidPointUsesSeededPrefix() async throws {
        // As if the user scrubbed to just before statement 1, then overrode
        // `doubled` to 999 (leaving `base` at its recorded 10).
        let fork = try await TraceReplayEngine.replay(
            source: source, featureSetName: "Doubler", startIndex: 1,
            seeds: ["base": 10, "doubled": 999]
        )
        XCTAssertNil(fork.error)
        // Statement 0 was NOT re-run, so `doubled` keeps the injected 999…
        XCTAssertEqual(latest(fork, "doubled"), "999")
        // …and the downstream Compute reflects it: 999 + 5 = 1004.
        XCTAssertEqual(latest(fork, "plus"), "1004")
        // First captured step is the re-entry point, not statement 0.
        XCTAssertEqual(fork.steps.first?.index, 1)
    }

    /// String trace values re-type correctly for seeding.
    func testReconstructTypesValues() {
        XCTAssertEqual(TraceReplayEngine.reconstruct("42") as? Int, 42)
        XCTAssertEqual(TraceReplayEngine.reconstruct("3.14") as? Double, 3.14)
        XCTAssertEqual(TraceReplayEngine.reconstruct("true") as? Bool, true)
        XCTAssertEqual(TraceReplayEngine.reconstruct("hello") as? String, "hello")
        let obj = TraceReplayEngine.reconstruct("{\"n\": 7}") as? [String: any Sendable]
        XCTAssertEqual(obj?["n"] as? Int, 7)
    }

    /// An unknown feature set surfaces a clear error rather than crashing.
    func testUnknownFeatureSetThrows() async {
        do {
            _ = try await TraceReplayEngine.replay(
                source: source, featureSetName: "Nope", startIndex: 0, seeds: [:]
            )
            XCTFail("expected featureSetNotFound")
        } catch let e as TraceReplayEngine.ReplayError {
            if case .featureSetNotFound = e { /* ok */ } else { XCTFail("wrong error: \(e)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
