// ============================================================
// BodyMaterializationTests.swift
// Does this feature set read its request body? (GitLab #477)
// ============================================================

import Testing
import Foundation
@testable import AROParser

@Suite("Body materialization analysis (#477)")
struct BodyMaterializationTests {

    private func analyze(_ source: String) -> [String: BodyMaterialization] {
        let result = Compiler().compile(source)
        return BodyMaterializationAnalyzer.analyze(result.program.featureSets)
    }

    // MARK: - Moving the body

    @Test("writing the body to a file never reads it")
    func writeStreams() {
        let summaries = analyze("""
        (uploadDocument: Files) {
            Extract the <name> from the <pathParameters: name>.
            Extract the <upload> from the <request: body>.
            Write the <upload> to the <file: name>.
            Return a <Created: status> with <name>.
        }
        """)
        #expect(summaries["uploadDocument"]?.materializes == false)
    }

    @Test("returning the body writes it back out without reading it")
    func returnStreams() {
        let summaries = analyze("""
        (echoBody: Files) {
            Extract the <payload> from the <request: body>.
            Return an <OK: status> with <payload>.
        }
        """)
        #expect(summaries["echoBody"]?.materializes == false)
    }

    @Test("emitting the body is a move — the runtime anchors it")
    func emitStreams() {
        let summaries = analyze("""
        (archiveDocument: Files) {
            Extract the <upload> from the <request: body>.
            Emit a <DocumentReceived: event> with <upload>.
            Return an <Accepted: status> for the <archive>.
        }
        """)
        #expect(summaries["archiveDocument"]?.materializes == false)
    }

    @Test("iterating the body streams it")
    func forEachStreams() {
        let summaries = analyze("""
        (scanUpload: Files) {
            Extract the <upload> from the <request: body>.
            for each <chunk> in <upload> {
                Send the <chunk> to the <upstream>.
            }
            Return an <OK: status> for the <scan>.
        }
        """)
        #expect(summaries["scanUpload"]?.materializes == false)
    }

    // MARK: - Reading the body

    @Test("a field access reads the body")
    func fieldAccessMaterializes() {
        let summaries = analyze("""
        (createNote: Notes) {
            Extract the <note> from the <request: body>.
            Extract the <text> from the <note: text>.
            Return a <Created: status> with <text>.
        }
        """)
        let summary = summaries["createNote"]
        #expect(summary?.materializes == true)
        #expect(summary?.statement?.contains("note") == true)
    }

    @Test("reading a field straight off the body reads the body")
    func directFieldAccessMaterializes() {
        let summaries = analyze("""
        (createNote: Notes) {
            Extract the <text> from the <request: body.text>.
            Return a <Created: status> with <text>.
        }
        """)
        #expect(summaries["createNote"]?.materializes == true)
    }

    @Test("logging the body reads it")
    func logMaterializes() {
        let summaries = analyze("""
        (traceBody: Debug) {
            Extract the <payload> from the <request: body>.
            Log <payload> to the <console>.
            Return an <OK: status> for the <trace>.
        }
        """)
        #expect(summaries["traceBody"]?.materializes == true)
    }

    @Test("computing over the body reads it, unless the qualifier can fold")
    func computeMaterializes() {
        let summaries = analyze("""
        (shoutBody: Files) {
            Extract the <payload> from the <request: body>.
            Compute the <loud: uppercase> from <payload>.
            Return an <OK: status> with <loud>.
        }
        """)
        // `uppercase` needs every byte at once; `sha256` does not — see
        // `digestStreams` below.
        #expect(summaries["shoutBody"]?.materializes == true)
    }

    @Test("storing the body in a repository reads it")
    func storeMaterializes() {
        let summaries = analyze("""
        (keepNote: Notes) {
            Extract the <note> from the <request: body>.
            Store the <note> to the <note-repository>.
            Return a <Created: status> for the <note>.
        }
        """)
        #expect(summaries["keepNote"]?.materializes == true)
    }

    // MARK: - Conservative by default

    @Test("a feature set that never touches the body counts as buffered")
    func noBodyIsBuffered() {
        let summaries = analyze("""
        (listNotes: Notes) {
            Retrieve the <notes> from the <note-repository>.
            Return an <OK: status> with <notes>.
        }
        """)
        // Nothing to stream: the empty buffer costs nothing and keeps the
        // default limit in place.
        #expect(summaries["listNotes"]?.materializes == true)
    }

    @Test("an unknown verb counts as reading")
    func unknownVerbMaterializes() {
        let summaries = analyze("""
        (scanUpload: Files) {
            Extract the <upload> from the <request: body>.
            Markdown.ToHTML the <rendered> from <upload>.
            Return an <OK: status> with <rendered>.
        }
        """)
        #expect(summaries["scanUpload"]?.materializes == true)
    }

    @Test("a guard that inspects the body reads it")
    func guardMaterializes() {
        let summaries = analyze("""
        (guardedUpload: Files) {
            Extract the <upload> from the <request: body>.
            Return a <Created: status> for the <upload> when <upload> is not empty.
        }
        """)
        #expect(summaries["guardedUpload"]?.materializes == true)
    }

    // MARK: - Across a user-defined action (ARO-0081)

    @Test("a call propagates to the callee: an action that only moves it streams")
    func callToStreamingActionStreams() {
        let summaries = analyze("""
        (StoreIt: Action takes <payload>) {
            Extract the <bytes> from the <input: payload>.
            Write the <bytes> to the <file: "/tmp/x">.
            Return an <OK: status> for the <store>.
        }

        (uploadDocument: Files) {
            Extract the <upload> from the <request: body>.
            Application.StoreIt the <done> from <upload>.
            Return a <Created: status> for the <upload>.
        }
        """)
        #expect(summaries["uploadDocument"]?.materializes == false)
    }

    @Test("a call propagates to the callee: an action that reads it reads it")
    func callToReadingActionMaterializes() {
        let summaries = analyze("""
        (Inspect: Action takes <payload>) {
            Extract the <bytes> from the <input: payload>.
            Compute the <loud: uppercase> from <bytes>.
            Return an <OK: status> with <loud>.
        }

        (uploadDocument: Files) {
            Extract the <upload> from the <request: body>.
            Application.Inspect the <report> from <upload>.
            Return a <Created: status> for the <upload>.
        }
        """)
        #expect(summaries["uploadDocument"]?.materializes == true)
    }

    // MARK: - Folding qualifiers (#486)

    @Test("hashing the body folds over it instead of reading it")
    func digestStreams() {
        let summaries = analyze("""
        (digestBody: Files) {
            Extract the <payload> from the <request: body>.
            Compute the <digest: sha256> from <payload>.
            Return an <OK: status> with <digest>.
        }
        """)
        #expect(summaries["digestBody"]?.materializes == false)
    }

    @Test("counting the body's bytes folds over it")
    func byteCountStreams() {
        let summaries = analyze("""
        (sizeOfBody: Files) {
            Extract the <payload> from the <request: body>.
            Compute the <size: length> from <payload>.
            Return an <OK: status> with <size>.
        }
        """)
        #expect(summaries["sizeOfBody"]?.materializes == false)
    }

    @Test("a qualifier that is not a fold still reads the body")
    func nonFoldingQualifierMaterializes() {
        let summaries = analyze("""
        (shoutBody: Files) {
            Extract the <payload> from the <request: body>.
            Compute the <loud: uppercase> from <payload>.
            Return an <OK: status> with <loud>.
        }
        """)
        #expect(summaries["shoutBody"]?.materializes == true)
    }

    // MARK: - Policy table

    @Test("the consumption table classifies the verbs it claims to")
    func policyTable() {
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Write") == .elementWise)
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Return") == .elementWise)
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Emit") == .elementWise)
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Extract") == .passThrough)
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Log") == .wholeValue)
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Store") == .wholeValue)
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Compute") == .wholeValue)
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Anything.Else") == .wholeValue)

        // Qualifier-aware: Compute folds when its qualifier can.
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Compute", resultQualifiers: ["sha256"]) == .elementWise)
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Compute", resultQualifiers: ["length"]) == .elementWise)
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Compute", resultQualifiers: ["uppercase"]) == .wholeValue)
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Compute", resultQualifiers: []) == .wholeValue)
        // A chain folds only if every step does.
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Compute", resultQualifiers: ["lines|length"]) == .elementWise)
        #expect(StreamConsumptionPolicy.consumption(ofVerb: "Compute", resultQualifiers: ["lines|uppercase"]) == .wholeValue)
    }
}
