// ============================================================
// DebugSourceFileAttributionTests.swift
// ARORuntimeTests - per-feature-set source attribution (GitLab #555)
// ============================================================
//
// `Debug.currentSourceFile` is one value for a whole session, and the CLI set
// it to the *first* source file. Every statement in every file therefore
// reported `main.aro`, so a breakpoint on `orders.aro:12` could never match —
// and `b 12`, documented as picking up the file of the current pause, picked up
// the wrong one. `Debug.sourceFileIndex` carries the per-feature-set answer.

import Testing
@testable import ARORuntime

@Suite("Debug source-file attribution (GitLab #555)")
struct DebugSourceFileAttributionTests {

    @Test("A feature set in the index is attributed to its own file")
    func indexWins() async {
        await Debug.$currentSourceFile.withValue("main.aro") {
            await Debug.$sourceFileIndex.withValue(["Second": "orders.aro"]) {
                #expect(Debug.sourceFile(forFeatureSet: "Second") == "orders.aro")
            }
        }
    }

    @Test("A feature set outside the index falls back to the session value")
    func fallbackForUnknown() async {
        await Debug.$currentSourceFile.withValue("main.aro") {
            await Debug.$sourceFileIndex.withValue(["Second": "orders.aro"]) {
                // A plugin's .aro files never went through the CLI's compile
                // loop, so they are not in the index. They keep the old
                // behaviour rather than losing attribution entirely.
                #expect(Debug.sourceFile(forFeatureSet: "FromAPlugin") == "main.aro")
            }
        }
    }

    @Test("An empty index leaves every feature set exactly as it was before")
    func emptyIndexIsTheOldBehaviour() async {
        await Debug.$currentSourceFile.withValue("main.aro") {
            #expect(Debug.sourceFileIndex.isEmpty)
            #expect(Debug.sourceFile(forFeatureSet: "Anything") == "main.aro")
        }
    }

    @Test("With neither set, attribution is empty — a line-only breakpoint still matches")
    func unknownIsEmpty() {
        #expect(Debug.sourceFile(forFeatureSet: "Anything") == "")
    }

    @Test("Each feature set gets its own file, not the first one compiled")
    func perFeatureSetNotPerSession() async {
        let index = [
            "Application-Start": "main.aro",
            "listUsers": "users.aro",
            "createOrder": "orders.aro",
        ]
        await Debug.$currentSourceFile.withValue("main.aro") {
            await Debug.$sourceFileIndex.withValue(index) {
                #expect(Debug.sourceFile(forFeatureSet: "Application-Start") == "main.aro")
                #expect(Debug.sourceFile(forFeatureSet: "listUsers") == "users.aro")
                #expect(Debug.sourceFile(forFeatureSet: "createOrder") == "orders.aro")
            }
        }
    }
}
