// ============================================================
// ToolResultEnvelope.swift
// AROAsk - one shape every tool result can be read through
// ============================================================
//
// GitLab #879. `AskToolDescriptor.execute` returns `String`, and each tool
// decided what that string looked like: numbered lines from `read_file`, CLI
// output from `aro_check`, a listing from `list_dir`, whatever the server
// sent from an MCP tool. Nothing could act on a result generically, because
// there was nothing common to act on.
//
// Three separate features want to:
//
//   - the compactor (#868) needs to know where the bodies are, so it can drop
//     them and keep everything else;
//   - a grounding check (#876) needs to know what was retrieved, to compare an
//     answer against it;
//   - a citation footer needs to know which files an answer drew on.
//
// So results carry a shape. The envelope is *optional* and additive: a tool
// that returns a plain string still works, and `ToolResultEnvelope.parse`
// simply finds nothing to work with. Nothing is forced into a shape it does
// not have — which is the right answer for MCP tools especially, whose output
// is the server's business and not ours.

import Foundation

/// One retrieved thing: where it came from, and what it said.
public struct ToolResultItem: Sendable, Equatable, Codable {
    /// Human-readable label — a file's path, a proposal's title.
    public var title: String
    /// Where this came from, as something a reader can follow. A
    /// workspace-relative file path for the file tools; a URL or a server
    /// name for anything external. This is the field that must survive
    /// compaction, because a link the model wrote earlier has to keep
    /// resolving after the body it quoted is gone.
    public var source: String
    /// The content itself. The only field compaction is allowed to take.
    public var body: String?

    public init(title: String, source: String, body: String? = nil) {
        self.title = title
        self.source = source
        self.body = body
    }
}

/// A tool result with its provenance intact.
///
/// `count` is the number of things found, which is not always
/// `items.count`: a search that matched 240 files and returned the first 20
/// reports 240, and the difference is what tells the model there is more.
public struct ToolResultEnvelope: Sendable, Equatable, Codable {
    /// How many results exist, of which `items` is the delivered prefix.
    public var count: Int
    /// The delivered results.
    public var items: [ToolResultItem]
    /// Free text for a tool whose output is a verdict rather than a list.
    ///
    /// `aro check` says "no issues found in 3 files"; that is not an item and
    /// pretending otherwise would give the compactor a body to drop and the
    /// citation footer a source to print, neither of which exists.
    public var text: String?

    public init(count: Int? = nil, items: [ToolResultItem] = [], text: String? = nil) {
        self.count = count ?? items.count
        self.items = items
        self.text = text
    }

    /// An envelope carrying only prose.
    public static func plain(_ text: String) -> ToolResultEnvelope {
        ToolResultEnvelope(count: 0, items: [], text: text)
    }

    /// An envelope for one retrieved file.
    ///
    /// `text` is the contents verbatim, because the model must go on reading
    /// exactly what it read before the envelope existed. The rendering below
    /// is for results that had no shape of their own; a file already has one.
    public static func file(path: String, contents: String) -> ToolResultEnvelope {
        ToolResultEnvelope(count: 1,
                           items: [ToolResultItem(title: path, source: path, body: contents)],
                           text: contents)
    }

    // MARK: - Wire format

    /// Marker introducing the machine-readable trailer.
    ///
    /// The envelope travels *with* the human-readable output rather than
    /// replacing it, because the model reads the output and a change to what
    /// it reads is a change to a fine-tuned model's input distribution. The
    /// trailer is one line, appended after the text, and the model has no
    /// reason to attend to it.
    static let marker = "\u{001B}[aro-tool-envelope]"

    /// This envelope with every body removed.
    ///
    /// What travels in the trailer is provenance, never content. The body is
    /// already in the visible output the model reads; putting it in the
    /// trailer too would double the token cost of every tool result, which
    /// is the opposite of what the compactor it feeds exists to do.
    public var metadataOnly: ToolResultEnvelope {
        ToolResultEnvelope(
            count: count,
            items: items.map { ToolResultItem(title: $0.title, source: $0.source) },
            text: nil)
    }

    /// The string a tool returns: its output, then the trailer.
    public func encoded() -> String {
        let visible = text ?? Self.render(items: items, count: count)
        guard let data = try? JSONEncoder().encode(metadataOnly),
              let json = String(data: data, encoding: .utf8) else {
            return visible
        }
        return visible + "\n" + Self.marker + json
    }

    /// The envelope carried by a tool result, if it has one.
    public static func parse(_ raw: String) -> ToolResultEnvelope? {
        guard let range = raw.range(of: marker, options: .backwards) else { return nil }
        let json = raw[range.upperBound...]
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ToolResultEnvelope.self, from: data)
    }

    /// The tool output with the trailer removed — what a human should see.
    public static func visible(_ raw: String) -> String {
        guard let range = raw.range(of: marker, options: .backwards) else { return raw }
        return String(raw[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace the trailer on an existing result, keeping its visible output.
    public static func reencode(_ raw: String, with envelope: ToolResultEnvelope) -> String {
        guard let data = try? JSONEncoder().encode(envelope.metadataOnly),
              let json = String(data: data, encoding: .utf8) else { return raw }
        return visible(raw) + "\n" + marker + json
    }

    /// Replace the visible output while keeping the trailer — what
    /// compaction does (GitLab #868).
    public static func replacingVisible(_ raw: String, with text: String) -> String {
        guard let range = raw.range(of: marker, options: .backwards) else { return text }
        return text + "\n" + String(raw[range.lowerBound...])
    }

    private static func render(items: [ToolResultItem], count: Int) -> String {
        guard !items.isEmpty else { return "No results." }
        var out = items.map { item -> String in
            if let body = item.body, !body.isEmpty {
                return "\(item.source):\n\(body)"
            }
            return item.source
        }.joined(separator: "\n\n")
        if count > items.count {
            out += "\n\n(\(count) results, showing \(items.count))"
        }
        return out
    }
}
