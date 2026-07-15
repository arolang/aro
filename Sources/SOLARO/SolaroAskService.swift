// ============================================================
// SolaroAskService.swift
// SOLARO — one shared, warm `aro ask` session for the editor's
//          inline suggestion surfaces (in-process, no subprocess)
// ============================================================
//
// The Actions-panel hover hint (ActionSuggester) and the AI
// autocomplete fallback (AICompletionFallback) used to spawn an
// `aro ask` subprocess per request. Because SOLARO already links
// the AROAsk module (see Package.swift), those one-line prompts
// can instead go through a single, prepared `AskSession` that
// loads the model once and stays warm — eliminating the
// per-call cold start (and the 12–20s watchdogs that guarded it).
//
// The session is deliberately *stateless* for these callers:
//
//  - It lives in an isolated cache working directory, so its
//    `.context` file never touches (or is polluted by) a project's
//    co-pilot conversation, which is rooted at the project dir.
//  - `clear()` runs before every prompt, so hover/autocomplete
//    requests don't accumulate history or replay each other.
//  - MCP is skipped (`skipMCP: true`) — one-liners need no external
//    tool servers, and spawning them would defeat the point of
//    avoiding subprocesses.
//
// If the model isn't already installed we return `nil` rather than
// silently downloading multiple GB from a hover; the suggestion is
// best-effort and the subprocess path behaved the same way (it had
// no TTY to confirm a download).

import Foundation

#if canImport(AROAsk)
import AROAsk

/// App-global holder for the shared suggestion session. Actor
/// isolation serialises preparation (one model load) and each
/// inference (the backend runs one request at a time anyway).
actor SolaroAskService {
    static let shared = SolaroAskService()

    private enum State {
        case idle
        case unavailable        // no model installed / prepare failed
        case ready(AskSession)
    }

    private var state: State = .idle
    /// In-flight preparation, so concurrent first-callers await the
    /// same model load instead of each starting their own.
    private var prepareTask: Task<AskSession?, Never>?

    /// Default model shipped with `aro ask` (matches AskCommand).
    private let model = "ARO-Lang/aro-coder-4bit"

    /// Isolated working directory: its `.context` / index stay out
    /// of every real project so suggestion calls can't leak into or
    /// corrupt a co-pilot conversation.
    private static let workingDirectory: URL = {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base
            .appendingPathComponent("aro-solaro", isDirectory: true)
            .appendingPathComponent("ask-suggest", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }()

    /// Fetch a one-shot completion for `prompt`, or `nil` on any
    /// error, timeout, or when the model isn't available. Stateless:
    /// the session is cleared before the prompt runs.
    ///
    /// - Parameter timeout: soft cap. The call returns after this
    ///   even if the backend is still working — the orphaned
    ///   inference finishes in the background and its result is
    ///   dropped, so the UI never hangs on a stuck model.
    func complete(_ prompt: String, timeout: TimeInterval = 15) async -> String? {
        guard let session = await ensureReady() else { return nil }

        // Stateless: drop any residue from a previous suggestion so
        // history can't accumulate or replay across calls.
        _ = try? await session.clear()

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                // `/no_think` mirrors the old `--no-think` flag: skip
                // Qwen3 reasoning so a one-liner doesn't burn the token
                // budget thinking.
                try? await session.ask("/no_think " + prompt)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Whether a suggestion backend is usable (model installed and
    /// prepared). Cheap after the first call.
    func isAvailable() async -> Bool {
        await ensureReady() != nil
    }

    // MARK: - Preparation

    private func ensureReady() async -> AskSession? {
        switch state {
        case .ready(let session): return session
        case .unavailable: return nil
        case .idle: break
        }
        if let task = prepareTask {
            return await task.value
        }
        let model = self.model
        let workDir = Self.workingDirectory
        let task = Task { () -> AskSession? in
            do {
                let manager = try ModelManager()
                // Never trigger a multi-GB download from a hover — only
                // proceed when the model is already on disk.
                guard await manager.isInstalled(model) else { return nil }
                let config = AskSessionConfig(
                    workingDirectory: workDir,
                    model: model,
                    autoApproveAll: true,   // read-only one-liners; no prompts
                    temperature: 0.2,
                    skipMCP: true
                )
                let session = AskSession(config: config)
                try await session.prepare(modelManager: manager)
                return session
            } catch {
                return nil
            }
        }
        prepareTask = task
        let result = await task.value
        state = result.map(State.ready) ?? .unavailable
        prepareTask = nil
        return result
    }
}
#endif
