// ============================================================
// ThinkingStripper.swift
// AROAsk - shared Qwen3 `<think>...</think>` removal
// ============================================================
//
// Single source of truth for stripping the model's internal reasoning
// from a reply. Used by every backend (native MLX, llama-server,
// remote OpenAI-compatible) and by the AskSession finalisation and
// repair paths, so all entry points have identical behaviour.

import Foundation

/// Result of stripping Qwen3-style `<think>...</think>` reasoning blocks
/// from a model reply.
struct StrippedReply: Equatable {
    /// The reply with thinking blocks (paired or unclosed) removed and
    /// surrounding whitespace trimmed.
    let text: String

    /// True iff the input contained a `<think>` opening tag and the
    /// resulting text is empty. Indicates the model spent its budget
    /// reasoning without producing a user-visible answer — usually a
    /// `maxTokens` exhaustion, sometimes a thinking loop.
    let truncatedDuringThinking: Bool
}

/// Strip Qwen3 thinking blocks from a model reply.
///
/// Handles:
///  - Multiple paired blocks: `<think>a</think>x<think>b</think>y` → `xy`
///  - Unclosed block at the end (token-budget truncation): `<think>a` → `""`
///  - Empty reply: passes through.
///
/// Idempotent. The result's `truncatedDuringThinking` flag lets the call
/// site surface a user-facing warning when the model burned its budget
/// without producing anything.
func stripThinking(_ text: String) -> StrippedReply {
    let hadOpenTag = text.contains("<think>")

    var stripped = text
    if let regex = try? NSRegularExpression(
        pattern: #"<think>[\s\S]*?</think>"#,
        options: [.dotMatchesLineSeparators]
    ) {
        let range = NSRange(stripped.startIndex..., in: stripped)
        stripped = regex.stringByReplacingMatches(
            in: stripped, range: range, withTemplate: ""
        )
    }

    // Truncation defense: any remaining `<think>` was opened but never
    // closed — the model ran out of budget mid-thinking. Drop from that
    // point so the user doesn't see raw chain-of-thought leaking out.
    if let openRange = stripped.range(of: "<think>") {
        stripped = String(stripped[..<openRange.lowerBound])
    }

    let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    return StrippedReply(
        text: trimmed,
        truncatedDuringThinking: hadOpenTag && trimmed.isEmpty
    )
}
