// ============================================================
// VerbMappingParityTests.swift
// ARO Runtime — a synonym must point at a verb that exists
// GitLab #722
// ============================================================
//
// Verb classification lives in six hand-maintained tables and only two of them
// had a parity test. `ActionRunner.verbMappings` was one of the four without,
// and it drifted: `forward → route` and `monitor`/`observe → watch` named verbs
// no `ActionImplementation` ever claimed, so a program written with the synonym
// failed at `executeAction` exactly as the bare verb did — while the table said
// the synonym was supported.
//
// The mapping is the *only* thing standing between a written verb and the
// registry, so this is the cheapest place to catch the next one.

import Testing
@testable import ARORuntime

@Suite("Verb mapping parity (#722)")
struct VerbMappingParityTests {

    private var registry: ActionRegistry { ActionRegistry.shared }

    @Test("Every canonical target is a verb some action implements")
    func everyTargetIsRegistered() {
        let dangling = ActionRunner.verbMappings
            .filter { !registry.isRegistered($0.value) }
            .map { "\($0.key) → \($0.value)" }
            .sorted()

        #expect(dangling.isEmpty,
                "these synonyms canonicalise to verbs no action implements: \(dangling)")
    }

    @Test("A synonym never belongs to a different action than its target")
    func noSynonymCrossesActions() {
        // Most synonyms here are *also* registered, because an action declares
        // its own synonyms in `verbs` — that is the design, not a fault. What
        // must never happen is a synonym registered to one action being
        // canonicalised to a verb belonging to another: the statement would run
        // the wrong action, and only in compiled binaries, whose dispatch table
        // is keyed by the canonical verb.
        //
        // `make` is the standing example. It belongs to `MakeAction` (directory
        // creation), so mapping it to `create` would send `Make the <directory>`
        // to `CreateAction`. The table says so in a comment; this asserts it.
        var crossed: [String] = []
        for (synonym, canonical) in ActionRunner.verbMappings {
            guard let synonymAction = registry.action(for: synonym),
                  let canonicalAction = registry.action(for: canonical) else { continue }
            if type(of: synonymAction) != type(of: canonicalAction) {
                crossed.append("\(synonym) [\(type(of: synonymAction))] → "
                             + "\(canonical) [\(type(of: canonicalAction))]")
            }
        }

        #expect(crossed.isEmpty,
                "these synonyms canonicalise into a different action: \(crossed.sorted())")
    }

    @Test("Canonicalising is idempotent")
    func canonicalisingIsIdempotent() {
        // A target that is itself a synonym would make the result depend on how
        // many times it was applied — and the compiled runtime's table is keyed
        // by canonical verb, so the two modes would disagree.
        for (synonym, canonical) in ActionRunner.verbMappings {
            let once = ActionRunner.canonicalizeVerb(synonym)
            #expect(once == ActionRunner.canonicalizeVerb(once),
                    "\(synonym) → \(canonical) → \(ActionRunner.canonicalizeVerb(once))")
        }
    }

    @Test("The synonyms the issue named now resolve or are gone")
    func theDriftedSynonymsAreGone() {
        // `route` and `watch` were deleted as phantoms (GitLab #698), so the
        // synonyms pointing at them went too. Writing them now fails as an
        // unknown verb, which is honest, rather than as a silent no-op.
        for gone in ["forward", "monitor", "observe"] {
            #expect(ActionRunner.verbMappings[gone] == nil,
                    "\(gone) still maps to a verb no action implements")
        }
    }
}
