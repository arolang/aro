// ============================================================
// GroundingCheckTests.swift
// AROAsk — is the answer true about this project? (GitLab #876)
// ============================================================
//
// The judge is deterministic, so every test here is a statement about the
// repo rather than about a model. The ones that matter most are the false
// positives: a check that fires on correct answers is the noise #823 is
// about, and would be worse than no check.

import Testing
import Foundation
@testable import AROAsk

@Suite("Grounding check (#876)")
struct GroundingCheckTests {

    /// A throwaway project with one real file and one real proposal.
    private func project() throws -> (URL, GroundingCheck) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-876-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Proposals"),
                               withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("Sources/Real.swift"))
        try Data("x".utf8).write(to: root.appendingPathComponent("Proposals/ARO-0042-sets.md"))
        return (root, GroundingCheck(root: root,
                                     proposalNumbers: GroundingCheck.proposalNumbers(in: root)))
    }

    @Test("A path that is not in the project is caught")
    func missingPathIsCaught() throws {
        let (root, check) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let findings = check.inspect(answer: "The logic lives in Sources/Imaginary.swift.")
        #expect(findings.count == 1)
        #expect(findings.first?.kind == .missingPath("Sources/Imaginary.swift"))
    }

    @Test("A path that is there is not")
    func realPathIsFine() throws {
        let (root, check) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(check.inspect(answer: "See Sources/Real.swift for the details.").isEmpty)
    }

    @Test("A proposal that does not exist is caught")
    func missingProposalIsCaught() throws {
        let (root, check) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let findings = check.inspect(answer: "ARO-0042 covers sets; ARO-9999 covers this.")
        #expect(findings.count == 1)
        #expect(findings.first?.kind == .missingProposal("ARO-9999"))
    }

    /// The failure this exists for: the model is fine-tuned on ARO and will
    /// confidently produce plausible ARO that is not in the language. Same
    /// shape as GitLab #486, in prose where no runtime will catch it.
    @Test("An invented qualifier is caught")
    func inventedQualifierIsCaught() throws {
        let (root, check) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let findings = check.inspect(answer: """
        ```aro
        Compute the <sorted: sortDescending> from the <items>.
        ```
        """)
        #expect(findings.count == 1)
        #expect(findings.first?.kind == .unknownQualifier("sortDescending"))
    }

    @Test("A real qualifier is fine")
    func realQualifierIsFine() throws {
        let (root, check) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(check.inspect(answer: "Compute the <n: length> from the <items>.").isEmpty)
    }

    /// `aro check` deliberately accepts a namespaced or chained qualifier,
    /// because it does not load plugins. A stricter judge here would reject
    /// code the toolchain accepts, which is worse than not judging.
    @Test("A plugin or chained qualifier is left alone")
    func uncheckableQualifiersAreSkipped() throws {
        let (root, check) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(check.inspect(answer: "Compute the <x: collections.pick-random> from the <y>.").isEmpty)
        #expect(check.inspect(answer: "Compute the <x: trim|uppercase> from the <y>.").isEmpty)
    }

    /// A check that fires on correct answers is the noise #823 is about.
    @Test("Ordinary prose is not read as a claim")
    func proseIsNotAClaim() throws {
        let (root, check) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let answers = [
            "A when guard runs the statement only if the condition holds.",
            "Feature sets are triggered by events, not called directly.",
            "The answer is 42. That is all.",
        ]
        for answer in answers {
            #expect(check.inspect(answer: answer).isEmpty, "false positive on: \(answer)")
        }
    }

    @Test("Each claim is reported once, however often it appears")
    func claimsAreDeduplicated() throws {
        let (root, check) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let findings = check.inspect(answer: """
        Look at Sources/Gone.swift. Then edit Sources/Gone.swift again.
        """)
        #expect(findings.count == 1)
    }

    /// The correction asks for the answer, not an apology.
    @Test("The correction names the problem and asks for the answer again")
    func correctionIsActionable() {
        let text = GroundingCheck.correction(for: [
            .init(kind: .missingPath("a/b.swift")),
            .init(kind: .unknownQualifier("nope")),
        ])
        #expect(text.contains("a/b.swift"))
        #expect(text.contains("nope"))
        #expect(text.contains("give the answer again"))
    }

    @Test("Proposal numbers are read from the directory")
    func proposalNumbersAreDiscovered() throws {
        let (root, _) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GroundingCheck.proposalNumbers(in: root) == ["ARO-0042"])
    }
}
