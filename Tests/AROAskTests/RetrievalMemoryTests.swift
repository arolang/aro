// ============================================================
// RetrievalMemoryTests.swift
// AROAsk — a second search returns other things (GitLab #874)
// ============================================================

import Testing
import Foundation
@testable import AROAsk

@Suite("Retrieval memory (#874)")
struct RetrievalMemoryTests {

    private func items(_ paths: [String]) -> [ToolResultItem] {
        paths.map { ToolResultItem(title: $0, source: $0, body: "body of \($0)") }
    }

    @Test("A first search has nothing to exclude")
    func firstSearchIsUntouched() async {
        let memory = RetrievalMemory()
        #expect(await memory.isEmpty)
        let (kept, skipped) = await memory.selectUnseen(from: items(["a", "b", "c"]), limit: 3)
        #expect(kept.map(\.source) == ["a", "b", "c"])
        #expect(skipped == 0)
    }

    /// The point of the whole thing: n *new* results, not n results the run
    /// has mostly seen. The gap left by the repeats is filled from further
    /// down the candidate list.
    @Test("A second search fills the gap from the next-best hits")
    func gapIsFilledWithNewResults() async {
        let memory = RetrievalMemory()
        _ = await memory.selectUnseen(from: items(["a", "b"]), limit: 2)

        let (kept, skipped) = await memory.selectUnseen(
            from: items(["a", "b", "c", "d", "e"]), limit: 2)
        #expect(kept.map(\.source) == ["c", "d"])
        #expect(skipped == 2)
    }

    /// A file that arrives three times looks to the model like three
    /// independent confirmations of whatever it says. That is the second
    /// cost of duplication, and the more expensive one.
    @Test("A source is delivered once, however many searches find it")
    func aSourceIsDeliveredOnce() async {
        let memory = RetrievalMemory()
        for _ in 0..<3 {
            _ = await memory.selectUnseen(from: items(["same.aro"]), limit: 5)
        }
        #expect(await memory.count == 1)
    }

    @Test("Paths are compared after standardising")
    func pathsAreNormalised() async {
        let memory = RetrievalMemory()
        _ = await memory.selectUnseen(from: items(["/tmp/x/../x/a.aro"]), limit: 1)
        #expect(await memory.hasDelivered("/tmp/x/a.aro"))
    }

    /// A result set that is quietly shorter than asked for reads as "there
    /// is nothing more", which is a different and false claim.
    @Test("Withholding repeats is said, not silent")
    func skippingIsAnnounced() {
        #expect(RetrievalMemory.skippedNotice(0) == nil)
        #expect(RetrievalMemory.skippedNotice(1)?.contains("1 result omitted") == true)
        #expect(RetrievalMemory.skippedNotice(3)?.contains("3 results omitted") == true)
    }

    @Test("Everything already seen yields nothing, and says so")
    func everythingSeenIsEmpty() async {
        let memory = RetrievalMemory()
        _ = await memory.selectUnseen(from: items(["a", "b"]), limit: 2)
        let (kept, skipped) = await memory.selectUnseen(from: items(["a", "b"]), limit: 2)
        #expect(kept.isEmpty)
        #expect(skipped == 2)
    }

    @Test("The limit is respected even when everything is new")
    func limitIsHonoured() async {
        let memory = RetrievalMemory()
        let (kept, _) = await memory.selectUnseen(from: items(["a", "b", "c", "d"]), limit: 2)
        #expect(kept.count == 2)
        // Only what was returned is recorded: a candidate that was never
        // shown to the model has not been delivered to it.
        #expect(await memory.count == 2)
        #expect(await memory.hasDelivered("c") == false)
    }
}
