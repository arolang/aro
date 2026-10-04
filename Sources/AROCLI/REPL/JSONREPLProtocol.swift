// ============================================================
// JSONREPLProtocol.swift
// ARO REPL — machine-readable protocol (`aro repl --json`)
// ============================================================
//
// One JSON object per line, in both directions, modelled on the MCP
// server's `StdioTransport` rather than on LSP: there is no Content-Length
// framing, a line is a message.
//
// The client sends requests; the server answers each one with exactly one
// `result` message carrying the same `id`, and may emit any number of
// unsolicited `stream` messages before it. That ordering is guaranteed —
// see `OutputCapture.drain` for how it is enforced across a real pipe.
//
// This is the protocol the Jupyter kernel speaks (Editor/jupyter-aro), but
// nothing in it is Jupyter-specific; it is the general "drive an ARO REPL
// from another program" surface.

import Foundation

// MARK: - Requests

/// A request from the client. Unknown `type`s are answered with an error
/// rather than ignored, so a client bug surfaces immediately instead of
/// hanging on a reply that never comes.
struct JSONREPLRequest: Decodable {
    let id: Int
    let type: String
    /// Cell source for `execute` / `is_complete` / `complete` / `inspect`.
    let code: String?
    /// Cursor offset (UTF-8 character index) for `complete` / `inspect`.
    let cursor: Int?
    /// Stable identity of the notebook cell being executed, when the
    /// front-end has one. Re-running the same cell releases the
    /// bindings that cell made rather than refusing them as a rebind
    /// (GitLab #544). Absent for a plain REPL line, which keeps the
    /// session-wide immutability rule.
    let cellId: String?
    /// Whether this `execute` may ask the client a question —
    /// `Prompt`, `Select`, `Ask` (GitLab #690). Named after Jupyter's
    /// `allow_stdin`, which is the same promise, so a kernel can pass
    /// its front-end's answer straight through.
    ///
    /// **Absent means false.** A client that has never heard of
    /// `input_request` would otherwise be sent one and never reply, and
    /// the cell would wait out the whole timeout before failing. Opting
    /// in costs one field; the honest refusal is the default.
    let allowStdin: Bool?
    /// The answer, on a request of type `input_reply`. Its `id` is the
    /// id of the `execute` that asked.
    let value: String?
    /// `"error"` on an `input_reply` means the client will not answer
    /// (the user dismissed the prompt). The statement then fails the way
    /// it fails when nobody can answer, instead of waiting.
    let status: String?
}

// MARK: - Responses

/// Status of a `result` message. `complete` / `incomplete` / `invalid` are
/// the `is_complete` vocabulary, named to match Jupyter's so the kernel is a
/// pass-through rather than a translation layer.
enum JSONREPLStatus: String {
    case ok
    case error
    case complete
    case incomplete
    case invalid
}

/// A structured error, shaped for Jupyter's `error` message.
///
/// ARO's own error text (ARO-0006, "code is the error message") is already a
/// multi-line block naming the feature, statement, and trace. It is split
/// here rather than rewritten: first line as `evalue`, whole block as
/// `traceback`, so nothing the runtime said is lost on the way to the cell.
struct JSONREPLError {
    let name: String
    let value: String
    let traceback: [String]

    init(name: String = "AROError", message: String) {
        self.name = name
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        self.value = lines.first ?? message
        self.traceback = lines
    }

    var payload: [String: Any] {
        ["ename": name, "evalue": value, "traceback": traceback]
    }
}

// MARK: - Encoding

/// Builds the line-delimited JSON messages the server writes.
///
/// `JSONSerialization` is used with `.fragmentsAllowed` because a display
/// bundle legitimately carries scalars (`application/json` of `42`), which
/// the default top-level-container rule would reject.
enum JSONREPLEncoder {
    static func line(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .fragmentsAllowed]
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            // Never let an unencodable payload break the stream: answer with
            // something the client can parse and report.
            return #"{"type":"result","status":"error","ename":"ProtocolError","evalue":"response was not JSON-encodable"}"#
        }
        return json
    }

    static func result(id: Int, status: JSONREPLStatus, extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": "result", "id": id, "status": status.rawValue]
        for (key, value) in extra {
            object[key] = value
        }
        return line(object)
    }

    static func stream(id: Int, name: String, text: String) -> String {
        line(["type": "stream", "id": id, "name": name, "text": text])
    }

    /// A question from the server, mid-`execute` (GitLab #690).
    ///
    /// Deliberately shaped like Jupyter's `input_request` — `prompt` and
    /// `password`, answered by an `input_reply` carrying `value` — so a
    /// kernel sitting between the two is a relay and not a translator,
    /// and a reader of one protocol already knows the other.
    ///
    /// It arrives *between* a request and its `result`, which is the one
    /// place the protocol's "exactly one result per request" rule needed
    /// a companion message rather than a new request type.
    static func inputRequest(id: Int, prompt: String, password: Bool) -> String {
        line(["type": "input_request", "id": id, "prompt": prompt, "password": password])
    }
}
