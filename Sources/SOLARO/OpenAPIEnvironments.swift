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

struct OpenAPIHistoryEntry: Codable {
    let timestamp: Date
    let environment: String
    let method: String
    let path: String
    let status: Int
    let durationMS: Int
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
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([OpenAPIEnvironment].self, from: data)
        {
            return list.isEmpty ? OpenAPIEnvironment.default : list
        }
        return OpenAPIEnvironment.default
    }

    static func save(_ envs: [OpenAPIEnvironment], in project: Project) {
        let url = envsURL(in: project)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(envs) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Append a history entry as one JSON line. Used for the
    /// per-project request log so the user can re-fire recent
    /// calls without retyping.
    static func appendHistory(_ entry: OpenAPIHistoryEntry, in project: Project) {
        let url = historyURL(in: project)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)
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
