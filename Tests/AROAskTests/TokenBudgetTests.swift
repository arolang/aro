// ============================================================
// TokenBudgetTests.swift
// AROAsk — measured, not guessed (GitLab #870, #869)
// ============================================================

import Testing
import Foundation
@testable import AROAsk

@Suite("Token budget (#870, #869)")
struct TokenBudgetTests {

    private func messages(chars: Int) -> [AskMessage] {
        [AskMessage(role: "user", content: String(repeating: "x", count: chars))]
    }

    /// A backend that reports nothing must leave the budget exactly where it
    /// was. This is what makes the change additive rather than a migration:
    /// nothing that worked before behaves differently until a real count
    /// arrives.
    @Test("Before anything is measured, the old estimate stands")
    func coldStartMatchesTheOldConstant() async {
        let budget = TokenBudget(window: 8192)
        // 400 characters + 4 framing = 404; the old code was (404 + 3) / 4.
        #expect(await budget.tokens(in: messages(chars: 400)) == 101)
        #expect(await budget.isCalibrated == false)
    }

    @Test("A reported count replaces the guess")
    func usageCalibratesTheRatio() async {
        let budget = TokenBudget(window: 8192)
        // 1000 characters really cost 200 tokens → 5.0 chars/token, not 4.
        await budget.observe(usage: LMUsage(promptTokens: 200), promptCharacters: 1000)
        #expect(await budget.isCalibrated)
        #expect(abs(await budget.charsPerToken - 5.0) < 0.001)
        // The same text now costs fewer tokens than the guess said, which is
        // the point: the guess compacts earlier than it needs to.
        #expect(await budget.tokens(in: messages(chars: 1000)) < 251)
    }

    /// One request is one mixture of prose and code; the next is another.
    /// The run's ratio is what the budget wants, not the last turn's.
    @Test("Samples are averaged, not replaced")
    func samplesAverage() async {
        let budget = TokenBudget(window: 8192)
        await budget.observe(usage: LMUsage(promptTokens: 250), promptCharacters: 1000) // 4.0
        await budget.observe(usage: LMUsage(promptTokens: 167), promptCharacters: 1000) // ~6.0
        let ratio = await budget.charsPerToken
        #expect(ratio > 4.5 && ratio < 5.5)
    }

    /// A ratio outside the plausible range is not a corpus, it is a bug — a
    /// truncated body, a count of something else. One bad sample must not
    /// move the budget.
    @Test("An implausible ratio is ignored")
    func implausibleSamplesRejected() async {
        let budget = TokenBudget(window: 8192)
        await budget.observe(usage: LMUsage(promptTokens: 1), promptCharacters: 100_000)
        #expect(await budget.isCalibrated == false)
        await budget.observe(usage: LMUsage(promptTokens: 100_000), promptCharacters: 100)
        #expect(await budget.isCalibrated == false)
    }

    @Test("Missing usage changes nothing")
    func nilUsageIsIgnored() async {
        let budget = TokenBudget(window: 8192)
        await budget.observe(usage: nil, promptCharacters: 1000)
        await budget.observe(usage: LMUsage(promptTokens: nil), promptCharacters: 1000)
        #expect(await budget.isCalibrated == false)
    }

    // MARK: - The output reservation (#869)

    /// The overflow this prevents is arithmetic, not failure: the reservation
    /// was never going to be used in full, and trimming it costs nothing.
    @Test("A reservation that does not fit is trimmed, not refused")
    func reservationIsTrimmed() async {
        let budget = TokenBudget(window: 32768)
        // ~24 500 tokens of prompt at the default ratio.
        let big = messages(chars: 98_000)
        let allowance = await budget.outputAllowance(for: big, requested: 8192)
        #expect(allowance != nil)
        #expect(allowance! < 8192)
        #expect(allowance! >= 512)
    }

    @Test("A reservation that fits is left alone")
    func smallPromptKeepsItsRequest() async {
        let budget = TokenBudget(window: 32768)
        #expect(await budget.outputAllowance(for: messages(chars: 400), requested: 4096) == 4096)
    }

    /// When even the floor does not fit there is nothing left to give on the
    /// output side, and the caller has to shrink the conversation instead —
    /// which is what the compactor is for (#868).
    @Test("A prompt that fills the window returns nil, not a useless allowance")
    func overfullPromptSignalsCompaction() async {
        let budget = TokenBudget(window: 4096)
        #expect(await budget.outputAllowance(for: messages(chars: 40_000), requested: 1024) == nil)
    }

    @Test("A measured prompt count beats the estimate for the allowance")
    func measuredCountIsPreferred() async {
        let budget = TokenBudget(window: 32768)
        let msgs = messages(chars: 4000)
        // The estimate says ~1000 tokens; the backend says the truth is 30000.
        await budget.observe(usage: LMUsage(promptTokens: 30_000), promptCharacters: 120_000)
        let allowance = await budget.outputAllowance(for: msgs, requested: 8192)
        #expect(allowance != nil && allowance! < 8192)
    }

    @Test("The window follows the model manifest")
    func windowIsSettable() async {
        let budget = TokenBudget(window: 8192)
        await budget.setWindow(32768)
        #expect(await budget.window == 32768)
        await budget.setWindow(0)   // nonsense is ignored rather than adopted
        #expect(await budget.window == 32768)
    }
}
