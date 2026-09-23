// ============================================================
// TokenBudget.swift
// AROAsk - how big this conversation is, and what still fits
// ============================================================
//
// GitLab #870 and #869.
//
// `estimateTokens` was `(chars + 3) / 4`, and it decided when the
// conversation got summarised — so the accuracy of that constant was the
// accuracy of the whole context policy. Four is a guess about English prose.
// The content here is ARO source (`<angle-bracket>` identifiers, hyphenated
// compound names, `(Feature Name: Business Activity)` headers) and JSON
// tool-call payloads with quoted keys and escaped newlines. Neither
// tokenises at four characters each, and they do not miss in the same
// direction.
//
// Every reply carries, or can carry, the number the estimate is guessing at:
// `usage.prompt_tokens` is the tokenizer's count of the very body that was
// sent. Dividing one by the other gives the ratio this corpus actually has.
// On macOS the native MLX backend has the tokenizer in-process and reports
// an exact count, so there is nothing to infer at all.
//
// The estimate stays as the cold-start value. The first reply replaces it.

import Foundation

/// What the conversation costs, and what is left.
public actor TokenBudget {

    /// Characters per token before anything has been measured.
    ///
    /// The value that was hard-coded as `/ 4`. Kept as the starting point so
    /// a first request behaves exactly as it did before, and so a backend
    /// that never reports usage is no worse off than it was.
    static let initialCharsPerToken = 4.0

    /// Ratio learned from what the backend reported.
    private var observedCharsPerToken: Double?
    /// How many replies have contributed to it.
    private var samples = 0
    /// The most recent measured prompt size, which is the one number that is
    /// not an estimate at all.
    private var lastMeasuredPromptTokens: Int?

    /// The model's context window, as the model manifest reports it.
    private(set) var window: Int

    public init(window: Int) {
        self.window = window
    }

    public func setWindow(_ value: Int) {
        guard value > 0 else { return }
        window = value
    }

    /// Characters per token, as currently believed.
    var charsPerToken: Double { observedCharsPerToken ?? Self.initialCharsPerToken }

    /// Whether the ratio is measured or still the initial guess.
    var isCalibrated: Bool { observedCharsPerToken != nil }

    /// Record what a reply reported.
    ///
    /// Averaged over samples rather than replaced, because one request is one
    /// mixture of prose and code and the next is another; the run's ratio is
    /// what the budget wants, not the last turn's.
    public func observe(usage: LMUsage?, promptCharacters: Int) {
        guard let promptTokens = usage?.promptTokens, promptTokens > 0,
              promptCharacters > 0 else { return }
        lastMeasuredPromptTokens = promptTokens
        let ratio = Double(promptCharacters) / Double(promptTokens)
        // A ratio outside this range is not a corpus, it is a bug — a
        // truncated body, a count of something else. Ignore it rather than
        // let one bad sample move the budget.
        guard ratio > 1.0, ratio < 12.0 else { return }
        if let current = observedCharsPerToken {
            observedCharsPerToken = (current * Double(samples) + ratio) / Double(samples + 1)
        } else {
            observedCharsPerToken = ratio
        }
        samples += 1
    }

    /// What this conversation costs, in tokens.
    public func tokens(in messages: [AskMessage]) -> Int {
        Self.tokens(in: messages, charsPerToken: charsPerToken)
    }

    /// The character count the estimate is derived from — what `observe`
    /// needs to pair with a reported token count.
    public static func characters(in messages: [AskMessage]) -> Int {
        messages.reduce(0) { total, msg in
            total + (msg.content?.count ?? 0)
                  + (msg.toolCalls?.count ?? 0)
                  + (msg.name?.count ?? 0)
                  + 4  // role + framing overhead
        }
    }

    static func tokens(in messages: [AskMessage], charsPerToken: Double) -> Int {
        let chars = characters(in: messages)
        return Int((Double(chars) / charsPerToken).rounded(.up))
    }

    /// How much room an answer still has, after the prompt (GitLab #869).
    ///
    /// The overflow this prevents is arithmetic, not failure: a prompt of
    /// 24 577 tokens and a reservation of 8 192 against a 32 768 window is
    /// over by exactly one token, and nothing about the answer required
    /// those 8 192 — the number was reserved and never used. So the
    /// reservation is trimmed to what is left. An answer written in 4 000
    /// tokens instead of 8 192 is the same answer; a refusal is no answer.
    ///
    /// Returns `nil` when even the floor does not fit, which is the caller's
    /// cue to shrink the conversation instead.
    public func outputAllowance(for messages: [AskMessage],
                                requested: Int,
                                floor: Int = 512) -> Int? {
        let prompt = lastMeasuredPromptTokens ?? tokens(in: messages)
        let room = window - prompt - Self.safetyMargin
        guard room >= floor else { return nil }
        return min(requested, room)
    }

    /// Slack for the chat template, the tool schemas, and the difference
    /// between an estimate and the truth. Small enough not to waste the
    /// window, large enough that being a little wrong is not a refusal.
    static let safetyMargin = 256

    /// Whether the conversation has grown past `fraction` of the window.
    public func exceeds(fraction: Double, messages: [AskMessage]) -> Bool {
        Double(tokens(in: messages)) > Double(window) * fraction
    }

    /// One line for `--verbose`, and for the session tally (#878).
    public func summary(for messages: [AskMessage]) -> String {
        let t = tokens(in: messages)
        let how = isCalibrated
            ? String(format: "measured %.2f chars/token over %d repl%@",
                     charsPerToken, samples, samples == 1 ? "y" : "ies")
            : "estimated"
        return "\(t)/\(window) tokens (\(how))"
    }
}
