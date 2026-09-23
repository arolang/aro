// ============================================================
// BailoutGuardTests.swift
// AROAsk — the turn ended without doing the work (GitLab #871)
// ============================================================
//
// The existing retries match shapes somebody observed. These two checks are
// structural — they look at what the turn *did* — so the tests that matter
// most are the ones showing a wording nobody wrote down still being caught,
// and an innocent wording not being.

import Testing
import Foundation
@testable import AROAsk

@Suite("Bail-out guard (#871)")
struct BailoutGuardTests {

    private let tools = ["read_file", "write_file", "aro_check", "grep"]

    // MARK: - Handing the reader a tool name

    /// `looksLikeDisguisedToolCall` deliberately lets prose through — "prose
    /// that merely names a tool is fine" — so this is the gap it leaves.
    @Test("An answer telling the reader to run a tool is caught")
    func proseHandOverIsCaught() {
        let answers = [
            "You can run aro_check on that directory to see the errors.",
            "You'll need to run grep for the pattern first.",
            "Use the read_file tool to look at the rest.",
            "Please run write_file with that content.",
        ]
        for answer in answers {
            #expect(BailoutGuard.handedOverToolName(in: answer, toolNames: tools) != nil,
                    "missed: \(answer)")
        }
    }

    /// `aro ask` is asked about its own tools often enough that a bare
    /// mention cannot be the signal. Documentation is not a hand-over.
    @Test("An answer explaining what a tool does is not a hand-over")
    func explanationIsNotHandOver() {
        let answers = [
            "read_file returns the file with line numbers.",
            "The aro_check tool validates syntax without executing anything.",
            "I used grep and found three matches.",
        ]
        for answer in answers {
            #expect(BailoutGuard.handedOverToolName(in: answer, toolNames: tools) == nil,
                    "false positive: \(answer)")
        }
    }

    /// A turn that acted and also mentioned a tool is explaining what it
    /// did, not handing work over.
    @Test("A turn that called tools is never accused of handing over")
    func actingTurnIsExempt() {
        let finding = BailoutGuard.inspect(
            answer: "You can run aro_check to confirm, but I already did.",
            toolNames: tools,
            toolCallsMade: ["read_file", "aro_check"],
            alreadyFired: [])
        #expect(finding == nil)
    }

    @Test("The longest matching tool name is reported")
    func longestNameWins() {
        let name = BailoutGuard.handedOverToolName(
            in: "You can run aro_check_all on it.",
            toolNames: ["aro_check", "aro_check_all"])
        #expect(name == "aro_check_all")
    }

    // MARK: - Writing ARO without checking it

    /// The one thing `aro ask` is supposed to be better at than a general
    /// assistant is not handing over ARO nobody verified.
    @Test("ARO in the answer with no aro_check is caught")
    func uncheckedCodeIsCaught() {
        let finding = BailoutGuard.inspect(
            answer: "Here you go:\n```aro\n(Main: App) {\n    Log \"hi\" to the <console>.\n}\n```",
            toolNames: tools,
            toolCallsMade: ["write_file"],
            alreadyFired: [])
        #expect(finding == .wroteCodeWithoutChecking)
    }

    @Test("ARO that was checked is fine")
    func checkedCodeIsFine() {
        let finding = BailoutGuard.inspect(
            answer: "```aro\n(Main: App) { Return an <OK: status> for the <x>. }\n```",
            toolNames: tools,
            toolCallsMade: ["write_file", "aro_check"],
            alreadyFired: [])
        #expect(finding == nil)
    }

    /// The requirement has to disappear with the tool. A session with no
    /// `aro_check` attached cannot be asked to have run it.
    @Test("With no aro_check attached, there is nothing to demand")
    func requirementFollowsTheTool() {
        let finding = BailoutGuard.inspect(
            answer: "```aro\n(Main: App) { }\n```",
            toolNames: ["read_file"],
            toolCallsMade: [],
            alreadyFired: [])
        #expect(finding == nil)
    }

    @Test("Prose about ARO is not code")
    func proseIsNotCode() {
        #expect(!BailoutGuard.containsAROCode("The ARO way is to use a when guard."))
        #expect(BailoutGuard.containsAROCode("```aro\nLog \"x\" to the <console>.\n```"))
    }

    // MARK: - Firing once

    /// Each nudge costs the reader a full regeneration of an answer they
    /// already watched arrive. A model that ignores the first will ignore
    /// the second.
    @Test("A finding already nudged about does not fire again")
    func findingsFireOnce() {
        let answer = "```aro\n(Main: App) { }\n```"
        let first = BailoutGuard.inspect(answer: answer, toolNames: tools,
                                         toolCallsMade: [], alreadyFired: [])
        #expect(first == .wroteCodeWithoutChecking)
        let second = BailoutGuard.inspect(answer: answer, toolNames: tools,
                                          toolCallsMade: [], alreadyFired: [first!])
        #expect(second == nil)
    }

    @Test("The nudge names the call to make")
    func nudgeNamesTheCall() {
        #expect(BailoutGuard.Finding.handedOverAToolName("grep").nudge.contains("grep"))
        #expect(BailoutGuard.Finding.wroteCodeWithoutChecking.nudge.contains("aro_check"))
    }
}
