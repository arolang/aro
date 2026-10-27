// ============================================================
// InteractiveInput.swift
// ARO Runtime — where `Prompt`, `Select` and `Ask` get their answer
// ============================================================
//
// `Prompt`, `Select` and `Ask` (ARO-0083 §5.2–5.3) used to read the
// process's own terminal and nothing else: the actions resolved
// `TerminalService`, which only exists when stdout is a TTY. Behind a
// pipe — the JSON REPL, the Jupyter kernel, SOLARO's notebook — there was
// no terminal, so the statement failed with `Service not registered:
// 'TerminalService'`, which tells a notebook user nothing they can act on
// (GitLab #690).
//
// The terminal is one *answerer*, not the only possible one. A notebook
// front-end can answer too, over a channel it already has (Jupyter's
// `input_request` / `input_reply` on the stdin channel; the matching
// `input_request` message in ARO's own JSON protocol). This file is the
// seam: an action asks whoever is registered, and the two front-ends
// register themselves.
//
// Three outcomes, and all three are finite:
//
//   * somebody answers     → the statement binds the answer
//   * nobody can answer    → the statement FAILS, naming the reason
//   * somebody could but
//     did not in time      → the statement fails on the timeout
//
// A cell that waits forever is the one outcome deliberately excluded: a
// user cannot tell a hung cell from a slow one, and interrupting a
// notebook costs the whole session (ARO-0091 §Interrupt).

import Foundation

// MARK: - The service

/// Something that can answer an interactive question on the user's behalf.
///
/// Implemented by `TerminalService` (reads the real TTY) and by each
/// notebook front-end (round-trips the question over its own protocol).
/// Registered on the execution context, so an action asks for the
/// capability rather than for a particular transport.
public protocol InteractiveInputService: Sendable {
    /// Ask for one line of free text.
    ///
    /// - Parameters:
    ///   - prompt: shown to the user; a front-end renders it next to its
    ///     input field, a terminal writes it before reading.
    ///   - hidden: the answer is a secret — do not echo it. A front-end
    ///     that cannot hide input must still answer (Jupyter's
    ///     `input_request` carries `password` for exactly this).
    /// - Returns: what the user typed, without its trailing newline.
    /// - Throws: `InteractiveInputError` when no answer is coming.
    func requestLine(prompt: String, hidden: Bool) async throws -> String

    /// Ask the user to choose among options.
    ///
    /// The default implementation renders a numbered menu and asks for a
    /// number, which is what every front-end can do; a front-end with a
    /// real picker overrides it.
    func requestChoice(prompt: String, options: [String], multiple: Bool) async throws -> [String]
}

public extension InteractiveInputService {

    /// Numbered menu over `requestLine`, so a front-end only has to
    /// implement one method to get both `Prompt` and `Select`.
    ///
    /// Written with `FileHandle` rather than `print` for the reason
    /// `LogAction` gives: `print` is fully buffered when stdout is not a
    /// terminal, and a menu that reaches the front-end *after* the
    /// question it belongs to is a question with no options under it.
    func requestChoice(prompt: String, options: [String], multiple: Bool) async throws -> [String] {
        var menu = prompt.isEmpty ? "" : prompt + "\n"
        for (index, option) in options.enumerated() {
            menu += "  \(index + 1). \(option)\n"
        }
        if let data = menu.data(using: .utf8) {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }

        let question = multiple
            ? "Enter selections (comma-separated numbers): "
            : "Enter selection (number): "
        let answer = try await requestLine(prompt: question, hidden: false)

        let picked = answer
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 && $0 <= options.count }
            .map { options[$0 - 1] }

        return multiple ? picked : Array(picked.prefix(1))
    }
}

// MARK: - Failure

/// Why an interactive question has no answer.
///
/// Each case is a sentence the user can act on, because the alternative
/// the user actually sees is a notebook cell that did nothing.
public enum InteractiveInputError: Error, CustomStringConvertible, Sendable {

    /// Nothing is registered that could answer: no terminal, no front-end
    /// input channel.
    case unavailable(action: String)

    /// A front-end exists but will not answer this one — Jupyter's
    /// `allow_stdin: false`, or the JSON protocol's `allowStdin` left off.
    case declined(action: String, detail: String)

    /// The channel is there and nobody replied. The way out of the wait.
    case timedOut(action: String, seconds: Double)

    /// The front-end went away mid-question: stdin reached EOF, or a
    /// shutdown arrived instead of a reply.
    case closed(action: String)

    public var description: String {
        switch self {
        case .unavailable(let action):
            return """
                Interactive input is not available here: there is no terminal and this \
                front-end offered no input channel, so `\(action)` has nobody to ask. \
                Run it in a terminal (`aro run`, `aro repl`), or use a notebook \
                front-end that implements the input channel — Jupyter's \
                `input_request`, or `"allowStdin": true` on an `execute` request of \
                the JSON protocol (ARO-0091 §Interactive input).
                """
        case .declined(let action, let detail):
            return """
                Interactive input is not available in this cell: \(detail), so \
                `\(action)` has nobody to ask. Allow input for the cell and run it \
                again (ARO-0091 §Interactive input).
                """
        case .timedOut(let action, let seconds):
            return """
                `\(action)` waited \(Self.render(seconds))s for an answer and the \
                front-end did not send one. ARO_INPUT_TIMEOUT_SECONDS sets the wait; \
                0 waits indefinitely.
                """
        case .closed(let action):
            return "`\(action)` asked for input and the front-end ended the session without answering."
        }
    }

    private static func render(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}

// MARK: - Resolution

/// Finds whoever can answer, in priority order.
public enum InteractiveInput {

    /// How long a front-end gets to answer before the statement fails.
    ///
    /// `ARO_INPUT_TIMEOUT_SECONDS=0` waits indefinitely, for a front-end
    /// whose user may legitimately take an hour; everything else gets a
    /// bounded wait, because the default must not be a cell that hangs.
    public static var timeoutSeconds: Double {
        guard let raw = ProcessInfo.processInfo.environment["ARO_INPUT_TIMEOUT_SECONDS"],
              let value = Double(raw), value >= 0
        else { return 300 }
        return value
    }

    /// The registered answerer, or nil when nothing can answer.
    ///
    /// A front-end channel wins over the terminal: in `aro repl --json`
    /// started from a terminal both can be present, and the client driving
    /// the session is the one whose user is looking at the question.
    public static func provider(in context: ExecutionContext) -> (any InteractiveInputService)? {
        if let frontEnd = context.service((any InteractiveInputService).self) {
            return frontEnd
        }
        return context.service(TerminalService.self)
    }

    /// The answerer, or a failure that says why there is none.
    public static func require(
        in context: ExecutionContext,
        action: String
    ) throws -> any InteractiveInputService {
        guard let provider = provider(in: context) else {
            throw ActionError.interactiveInputUnavailable(
                reason: InteractiveInputError.unavailable(action: action).description)
        }
        return provider
    }

    /// Run one request and turn its refusal into an `ActionError`, so the
    /// statement fails with the explanation rather than with a Swift error
    /// nobody wrote for a user.
    public static func answer<T: Sendable>(
        action: String,
        _ request: () async throws -> T
    ) async throws -> T {
        do {
            return try await request()
        } catch let error as InteractiveInputError {
            throw ActionError.interactiveInputUnavailable(reason: error.description)
        }
    }
}

// MARK: - The terminal as an answerer

/// The original answerer, unchanged in behaviour: `TerminalService` reads
/// the process's own TTY, which is the right answer for `aro run` and
/// `aro repl` and no answer at all behind a pipe.
extension TerminalService: InteractiveInputService {

    public func requestLine(prompt: String, hidden: Bool) async -> String {
        await self.prompt(message: prompt, hidden: hidden)
    }

    public func requestChoice(prompt: String, options: [String], multiple: Bool) async -> [String] {
        await select(options: options, message: prompt, multiSelect: multiple)
    }
}
