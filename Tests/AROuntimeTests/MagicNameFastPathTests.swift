// ============================================================
// MagicNameFastPathTests.swift
// ARO Runtime — the magic-name fast path agrees with the list
// (GitLab #710)
// ============================================================
//
// `<now>`, `<contract>`, `<metrics>` and friends are answered by
// the framework rather than by the variable store, so every
// variable read has to ask whether the name is one of them. Almost
// none of them is, and asking cost a seven-case string switch per
// read.
//
// `RuntimeContext.mayBeMagic` answers "no" from the first byte.
// That is only correct while the initials it accepts cover every
// name in `magicNames` — so this asserts exactly that, and that it
// still rejects the ordinary names it exists to reject.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Magic-name fast path (#710)")
struct MagicNameFastPathTests {

    @Test("Every magic name passes the first-byte filter")
    func everyMagicNamePasses() {
        for name in RuntimeContext.magicNames {
            #expect(RuntimeContext.mayBeMagic(name),
                    Comment(rawValue: "\(name) is magic but the fast path rejects it,"
                            + " so it would never resolve"))
        }
    }

    @Test("Ordinary names are rejected without hashing",
          arguments: ["users", "total", "_with_", "request", "order-id",
                      "j1", "result", "body", "Users", "x"])
    func ordinaryNamesAreRejected(name: String) {
        // Not a contract about these specific names — it is the point of the
        // filter. A filter that said yes to everything would pass the test
        // above and buy nothing.
        #expect(!RuntimeContext.mayBeMagic(name))
    }

    @Test("The filter is a filter, not a decision")
    func aPassingNameIsStillChecked() {
        // `client` starts with `c` and is not magic. The fast path lets it
        // through; `magicNames` is what actually decides.
        #expect(RuntimeContext.mayBeMagic("client"))
        #expect(!RuntimeContext.magicNames.contains("client"))
    }
}
