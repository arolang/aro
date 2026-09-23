// ============================================================
// OpenAPIEnvironments.swift
// SOLARO — env profiles + auth + history for try-it-out (#265)
// ============================================================
//
// Persists a small set of named environments (dev/staging/prod
// shape) to .solaro/openapi-envs.json, plus each request the
// user fires to .solaro/openapi-history.jsonl. Auth presets
// build the right headers on top of the env's defaults.
//
// Secrets — tokens, API keys, basic-auth passwords — are
// **never** persisted to disk. They live in memory on the
// TryItOutModel; switching environments wipes the token.
//
// `save` upholds that for the environment's own `defaultHeaders` too: an
// `Authorization` (or `Cookie`, or `X-Api-Key`) default would otherwise be
// written in clear into `.solaro/openapi-envs.json`, which sits inside the
// user's repository. It is redacted on the way out (GitLab #745).
//
// `save` has no caller today — environments are loaded from a file the user
// writes — so this is a guard against wiring it up later rather than a fix
// for something currently leaking. `.gitignore` covers the hand-written case
// (GitLab #777).

import Foundation

struct OpenAPIEnvironment: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var baseURL: String
    var defaultHeaders: [String: String]

    init(id: UUID = UUID(), name: String, baseURL: String,
         defaultHeaders: [String: String] = [:])
    {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.defaultHeaders = defaultHeaders
    }

    static let `default`: [OpenAPIEnvironment] = [
        .init(name: "local",   baseURL: "http://localhost:8080"),
        .init(name: "staging", baseURL: "https://staging.example.com"),
        .init(name: "prod",    baseURL: "https://api.example.com")
    ]
}

enum OpenAPIAuth: String, Codable, CaseIterable, Identifiable {
    case none, apiKey, bearer, basic
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:   return "None"
        case .apiKey: return "API Key"
        case .bearer: return "Bearer"
        case .basic:  return "Basic"
        }
    }
}

struct OpenAPIHistoryEntry: Codable, Identifiable {
    let timestamp: Date
    let environment: String
    let method: String
    let path: String
    let status: Int
    let durationMS: Int

    // Replay (#766). The history recorded that a request happened but
    // not what it was, so "send this one again" could only have meant
    // "send a different request to the same path". These carry the
    // values that made it a request.
    //
    // All optional, because entries written before this existed are
    // still in people's projects and must keep decoding — an entry
    // without them replays as far as it can, which is the path.
    var pathParameters: [String: String]?
    var queryParameters: [String: String]?
    var headers: [String: String]?
    var body: String?

    var id: String { "\(timestamp.timeIntervalSince1970):\(method):\(path)" }

    /// Whether this entry carries enough to be sent again as itself.
    ///
    /// An old entry does not, and the UI says so rather than offering
    /// a button that would quietly send something else.
    var isReplayable: Bool {
        pathParameters != nil || queryParameters != nil
            || headers != nil || body != nil
    }

    /// Secrets are not written to disk (#745, #755), so a replayed
    /// request takes its auth from the environment as it is now.
    static func redactingSecrets(_ headers: [String: String]) -> [String: String] {
        headers.filter { !OpenAPIEnvStore.isSecretHeader($0.key) }
    }
}

enum OpenAPIEnvStore {
    static func envsURL(in project: Project) -> URL {
        project.rootPath
            .appendingPathComponent(".solaro", isDirectory: true)
            .appendingPathComponent("openapi-envs.json")
    }

    static func historyURL(in project: Project) -> URL {
        project.rootPath
            .appendingPathComponent(".solaro", isDirectory: true)
            .appendingPathComponent("openapi-history.jsonl")
    }

    /// Load + return the persisted environments, seeded from the
    /// default trio when the file doesn't exist yet.
    static func loadEnvironments(in project: Project) -> [OpenAPIEnvironment] {
        let url = envsURL(in: project)
        // Missing or unreadable means "this project has no saved
        // environments yet", which is true of every project until the
        // first save; the default trio below is the answer either way.
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([OpenAPIEnvironment].self, from: data)
        {
            return list.isEmpty ? OpenAPIEnvironment.default : list
        }
        return OpenAPIEnvironment.default
    }

    /// Header names whose value is a credential, matched case-insensitively.
    ///
    /// `Authorization` and `Cookie` are the standard two; the rest are the
    /// conventional spellings of an API key. A header whose name merely
    /// *contains* "token" or "secret" counts too, which is deliberately
    /// broad: redacting one header too many costs a retype, redacting one too
    /// few writes a credential into the user's repository.
    static func isSecretHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        if ["authorization", "cookie", "proxy-authorization"].contains(lower) {
            return true
        }
        return lower.contains("api-key") || lower.contains("apikey")
            || lower.contains("token") || lower.contains("secret")
            || lower.contains("password")
    }

    static func save(_ envs: [OpenAPIEnvironment], in project: Project) {
        let url = envsURL(in: project)
        let dir = url.deletingLastPathComponent()
        // Already existing is the usual outcome and is not an error;
        // anything else that went wrong here shows up as a failed write
        // below, which does report.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let redacted = envs.map { env -> OpenAPIEnvironment in
            var copy = env
            copy.defaultHeaders = env.defaultHeaders.filter { !isSecretHeader($0.key) }
            return copy
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Encoding a value of our own type cannot realistically fail —
        // every field is a String, a Bool or a dictionary of them — and
        // there is nothing the user could do about it if it did.
        if let data = try? encoder.encode(redacted) {
            // A failed write loses the user's environments silently, so say so
            // rather than swallowing it (CLAUDE.md's `try?` rule).
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data(
                    "[OpenAPIEnvStore] Warning: could not save environments to \(url.path): \(error)\n".utf8
                ))
            }
        }
    }

    /// Append a history entry as one JSON line. Used for the
    /// per-project request log so the user can re-fire recent
    /// calls without retyping.
    /// Keep at most this many history entries. The file is appended to on
    /// every try-it-out request and was never capped or pruned, so it grew
    /// for the life of the project inside the user's repository (GitLab #746).
    static let historyLimit = 500

    /// Read the request log back, newest first (#766).
    ///
    /// One JSON object per line. A line that will not decode is
    /// skipped rather than failing the read: the file is appended to
    /// by a live process and a truncated last line is ordinary.
    static func loadHistory(in project: Project) -> [OpenAPIHistoryEntry] {
        let url = historyURL(in: project)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(OpenAPIHistoryEntry.self,
                                    from: Data(line.utf8))
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    static func appendHistory(_ entry: OpenAPIHistoryEntry, in project: Project) {
        let url = historyURL(in: project)
        let dir = url.deletingLastPathComponent()
        // As in `save` above: existing is the normal case.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Same argument as `save`: encoding our own flat type.
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        // The history is a convenience — it lets the user re-fire a
        // recent request without retyping it — and losing one line of
        // it costs one retype. That is the reason these stay `try?`
        // while the environments file itself reports (#755): warning on
        // every request that could not be logged would be noise out of
        // all proportion to what was lost. The open failing is the
        // expected path on a first write, which is what the `else` is.
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
        pruneHistory(at: url)
    }

    /// Trim the history to `historyLimit` lines, oldest first.
    ///
    /// Done after the append rather than before, so the common path is one
    /// `seekToEnd` + write and the rewrite happens only when the file is
    /// actually over the line count.
    private static func pruneHistory(at url: URL) {
        // Nothing readable to prune. The append above has its own
        // reasons for being best-effort, and this is downstream of it.
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > historyLimit else { return }
        lines.removeFirst(lines.count - historyLimit)
        let trimmed = lines.joined(separator: "\n") + "\n"
        do {
            try trimmed.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data(
                "[OpenAPIEnvStore] Warning: could not prune \(url.lastPathComponent): \(error)\n".utf8
            ))
        }
    }
}

/// Stateless cURL-string builder used by the "Save as cURL"
/// button in the try-it-out panel.
enum CurlExport {
    static func build(
        method: String,
        url: URL,
        headers: [String: String],
        body: String?
    ) -> String {
        var pieces: [String] = ["curl"]
        if method.uppercased() != "GET" {
            pieces.append("-X")
            pieces.append(method.uppercased())
        }
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) where !v.isEmpty {
            pieces.append("-H")
            pieces.append("'\(k): \(escape(v))'")
        }
        if let body, !body.isEmpty {
            pieces.append("--data")
            pieces.append("'\(escape(body))'")
        }
        pieces.append("'\(url.absoluteString)'")
        return pieces.joined(separator: " ")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }
}
