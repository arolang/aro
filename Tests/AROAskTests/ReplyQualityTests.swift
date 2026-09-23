// ============================================================
// ReplyQualityTests.swift
// AROAsk — a retry must not replace a good answer (GitLab #872)
// ============================================================

import Testing
import Foundation
@testable import AROAsk

@Suite("Reply quality (#872)")
struct ReplyQualityTests {

    private func reply(_ text: String, tools: Int = 0, truncated: Bool = false) -> ReplyQuality {
        let calls = (0..<tools).map {
            LMToolCall(id: "c\($0)", function: .init(name: "read_file", arguments: "{}"))
        }
        return ReplyQuality(text: text, toolCalls: calls.isEmpty ? nil : calls, truncated: truncated)
    }

    /// The bug: the old condition was "the retry said something", so a
    /// correct first answer was thrown away for a second nobody compared it
    /// against — after the user had already watched the first one stream.
    @Test("A retry that is merely different does not replace a good answer")
    func levelRetryKeepsTheOriginal() {
        let good = reply("Here is the feature set, and why it is shaped that way.")
        let other = reply("Here is the feature set, and why it is shaped that way!")
        #expect(!ReplyQuality.shouldReplace(current: good, with: other))
    }

    @Test("A retry that answers replaces one that did not")
    func answerBeatsNothing() {
        #expect(ReplyQuality.shouldReplace(current: reply(""), with: reply("An answer.")))
    }

    @Test("A retry that acts replaces one that only talked")
    func toolCallsBeatProse() {
        let talked = reply("You could run aro_check on that directory.")
        let acted = reply("", tools: 1)
        #expect(ReplyQuality.shouldReplace(current: talked, with: acted))
        #expect(!ReplyQuality.shouldReplace(current: acted, with: talked))
    }

    @Test("A complete answer beats a truncated one, however long")
    func completenessBeatsLength() {
        let cut = reply(String(repeating: "thinking… ", count: 200), truncated: true)
        let whole = reply("Short but finished.")
        #expect(ReplyQuality.shouldReplace(current: cut, with: whole))
        #expect(!ReplyQuality.shouldReplace(current: whole, with: cut))
    }

    /// An empty retry is the common failure mode — the model emits
    /// `<think></think>` and stops. It must never win.
    @Test("An unusable retry never replaces anything")
    func unusableRetryIsRejected() {
        let good = reply("An answer.")
        #expect(!ReplyQuality.shouldReplace(current: good, with: reply("")))
        #expect(!ReplyQuality.shouldReplace(current: good, with: reply("   \n  ")))
        #expect(!ReplyQuality.shouldReplace(current: good,
                                            with: reply("half a thought", truncated: true)))
    }

    /// Length is the last tiebreak and only that. Two otherwise
    /// indistinguishable replies have to be separated somehow, and longer is
    /// the better guess — but it must never outrank acting or finishing.
    @Test("Length only decides when nothing else does")
    func lengthIsTheLastResort() {
        #expect(ReplyQuality.shouldReplace(current: reply("short"),
                                           with: reply("a rather longer answer")))
        // …but not against a reply that acted.
        #expect(!ReplyQuality.shouldReplace(current: reply("", tools: 1),
                                            with: reply(String(repeating: "x", count: 9999))))
    }

    @Test("Usability is tool calls, or text that finished")
    func usability() {
        #expect(reply("An answer.").isUsable)
        #expect(reply("", tools: 1).isUsable)
        #expect(!reply("").isUsable)
        #expect(!reply("cut off", truncated: true).isUsable)
        // A truncated message that still managed a tool call is usable: the
        // call is the work, and it ran.
        #expect(reply("cut off", tools: 1, truncated: true).isUsable)
    }
}
