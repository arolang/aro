// ============================================================
// ReplyQuality.swift
// AROAsk - which of two replies to keep
// ============================================================
//
// GitLab #872. Each corrective retry in `AskSession.ask` overwrote the reply
// when the retry produced anything at all:
//
//     if !retryStripped.text.isEmpty || !(retryReply.toolCalls ?? []).isEmpty {
//         reply = retryReply
//     }
//
// The condition is "the retry said something", not "the retry is better". A
// first answer that was correct but tripped a heuristic was discarded for a
// second nobody compared it against — and the user had already watched the
// first one stream.
//
// The reference implementation has a whole file about this exact bug. Asked
// about the Future Meeting Space, their model opened with "Das dauert einen
// Moment — ich sehe mir die Quellen an." and then wrote four correct, sourced
// paragraphs; the guard matched the opening phrase, armed a correction, the
// rewrite opened with the same sentence, and the reader watched a good answer
// be replaced three times before the retry budget ran out.
//
// Two rules come out of that:
//
//   1. A trigger must require the rest of the message to be *absent*, not
//      merely the marker to be present. A `<think>` stall with four
//      paragraphs after it is not a stall — it is an answer with a preamble,
//      and the preamble is a line to delete.
//   2. When a retry does fire, keep the better of the two, not the later one.

import Foundation

/// How good a reply is, for the purpose of choosing between two of them.
///
/// Deliberately coarse. This is not a judgement of the answer's content —
/// nothing here can read ARO — it is the handful of signals that are checkable
/// without another model call, ordered so that a clear improvement wins and a
/// wash keeps what the user already saw.
struct ReplyQuality: Comparable {
    /// The reply produced tool calls. A run that acted beats one that talked.
    var hasToolCalls: Bool
    /// There is prose at all, after thinking is stripped.
    var hasText: Bool
    /// The reply was cut off mid-`<think>` and never reached an answer.
    var truncated: Bool
    /// Length, as the last tiebreak only.
    var length: Int

    init(text: String, toolCalls: [LMToolCall]?, truncated: Bool) {
        self.hasToolCalls = !(toolCalls ?? []).isEmpty
        self.hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.truncated = truncated
        self.length = text.count
    }

    /// Whether this reply is worth showing at all.
    var isUsable: Bool { hasToolCalls || (hasText && !truncated) }

    static func < (a: ReplyQuality, b: ReplyQuality) -> Bool {
        // Acting beats talking.
        if a.hasToolCalls != b.hasToolCalls { return !a.hasToolCalls }
        // A complete answer beats a truncated one.
        if a.truncated != b.truncated { return a.truncated }
        // Something beats nothing.
        if a.hasText != b.hasText { return !a.hasText }
        // Only now, length — and only as a tiebreak. A longer answer is not
        // a better one in general; it is merely the better guess when two
        // replies are otherwise indistinguishable from out here.
        return a.length < b.length
    }

    /// Whether `candidate` should replace `current`.
    ///
    /// Strictly better, not merely different. A retry that comes back level
    /// keeps the answer the user already watched arrive — replacing it costs
    /// them the wait and gains nothing measurable.
    static func shouldReplace(current: ReplyQuality, with candidate: ReplyQuality) -> Bool {
        candidate.isUsable && current < candidate
    }
}
