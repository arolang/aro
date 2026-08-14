// ============================================================
// SnippetLibrary.swift
// SOLARO — insertable multi-line ARO patterns (#242)
// ============================================================
//
// The Actions tab drags one statement at a time. The patterns
// people actually retype are bigger than that: a route triple, an
// emit + handler pair, an observer skeleton. This is that library.
//
// Three surfaces consume it, all from the same `AROSnippet.body`:
//   - the Snippets tab in the right rail (drag → editor / canvas)
//   - Tab-trigger expansion in the editor (`routes` + Tab)
//   - the custom snippets a project defines in .solaro/snippets/
//
// Placeholder syntax is `${label}`. Expansion strips the wrapper
// and keeps `label` as ordinary text, recording where it landed so
// the editor can select the first one after inserting. There is no
// escape for a literal `${` — ARO has no use for the sequence, and
// a snippet that needs one can spell it with a placeholder.

import Foundation
import Yams

// MARK: - Model

/// One insertable pattern.
struct AROSnippet: Identifiable, Hashable, Sendable {
    /// Where the snippet came from. Custom snippets carry the file
    /// they were read from so the row can say which one to edit.
    enum Origin: Hashable, Sendable {
        case builtIn
        case custom(fileName: String)

        var isCustom: Bool {
            if case .custom = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .builtIn:            return "Built-in"
            case .custom(let file):   return file
            }
        }
    }

    /// Display name, e.g. "Route triple (list / create / get)".
    var name: String
    /// One line describing when to reach for it.
    var summary: String
    /// Word the user types before Tab to expand this in the editor.
    /// Lowercase, no whitespace; empty disables tab expansion.
    var trigger: String
    /// Snippet source, `${placeholder}` tokens included.
    var body: String
    var origin: Origin

    var id: String { "\(origin.label)/\(name)" }

    /// True when the body declares its own feature set(s) rather
    /// than being a statement that belongs inside one. Drives where
    /// a canvas drop lands: whole feature sets append at end of
    /// file, statements go inside the feature set under the cursor.
    var isTopLevel: Bool {
        AROSnippet.topLevelPattern.firstMatch(
            in: body,
            range: NSRange(body.startIndex..., in: body)
        ) != nil
    }

    /// A line that opens a feature set: `(Name: Business Activity) {`,
    /// optionally after a comment or blank lines.
    private static let topLevelPattern: NSRegularExpression = {
        // Force-try: the pattern is a literal compiled once at
        // startup. A malformed literal is a programmer error that
        // would fail on the first launch, not a runtime condition.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^\s*\([^)\n]+:[^)\n]+\)\s*\{"#,
            options: [.anchorsMatchLines]
        )
    }()
}

// MARK: - Expansion

/// A snippet body with its `${…}` wrappers removed, plus where the
/// placeholder labels ended up.
struct SnippetExpansion: Equatable {
    /// Insertable text — no `${` or `}` wrappers left.
    var text: String
    /// UTF-16 ranges of each placeholder label, relative to `text`,
    /// in source order. Empty when the body had no placeholders.
    var placeholders: [NSRange]

    /// Range the editor should select after inserting. The first
    /// placeholder, or nil when there are none.
    var firstPlaceholder: NSRange? { placeholders.first }
}

enum SnippetExpander {
    /// Strip `${label}` wrappers and record the label ranges.
    ///
    /// `indent` is prefixed to every line after the first, so a
    /// snippet dropped at column 4 keeps its shape. Blank lines are
    /// left blank rather than filled with trailing whitespace.
    static func expand(_ body: String, indent: String = "") -> SnippetExpansion {
        let indented = indent.isEmpty ? body : reindent(body, by: indent)
        var out = ""
        var placeholders: [NSRange] = []
        var index = indented.startIndex
        // Track the UTF-16 length written so far — NSRange is
        // UTF-16-based and the editor's text storage is too.
        var utf16Count = 0

        while index < indented.endIndex {
            let ch = indented[index]
            if ch == "$",
               indented.index(after: index) < indented.endIndex,
               indented[indented.index(after: index)] == "{",
               let close = indented[index...].firstIndex(of: "}")
            {
                let labelStart = indented.index(index, offsetBy: 2)
                let label = String(indented[labelStart..<close])
                placeholders.append(
                    NSRange(location: utf16Count, length: label.utf16.count)
                )
                out += label
                utf16Count += label.utf16.count
                index = indented.index(after: close)
                continue
            }
            out.append(ch)
            utf16Count += String(ch).utf16.count
            index = indented.index(after: index)
        }
        return SnippetExpansion(text: out, placeholders: placeholders)
    }

    /// Prefix every line after the first with `indent`. The first
    /// line is left alone because it is spliced in at a caret that
    /// already sits at the right column.
    private static func reindent(_ body: String, by indent: String) -> String {
        // Split over Characters so a CRLF body doesn't come back as
        // one line on Linux Foundation (same trap as GitLab #486).
        let lines = body.split(omittingEmptySubsequences: false,
                               whereSeparator: \.isNewline)
        guard lines.count > 1 else { return body }
        return lines.enumerated().map { offset, line in
            if offset == 0 || line.isEmpty { return String(line) }
            return indent + line
        }.joined(separator: "\n")
    }
}

// MARK: - Splicing a snippet into a buffer

/// The text math behind "insert this snippet at the caret",
/// separated from the file I/O so it can be tested without a
/// workspace. CenterPane owns the write + reparse; this owns where
/// the characters go.
enum SnippetSplice {
    struct Result: Equatable {
        /// The whole updated buffer.
        var text: String
        /// Absolute UTF-16 range of the first placeholder, for the
        /// editor to select. Nil when the snippet had none.
        var selection: NSRange?
        /// Absolute UTF-16 offset just past the inserted text —
        /// where the caret goes when there is no placeholder.
        var caretOffset: Int
    }

    /// Splice `body` into `source` at (1-based `line`, 0-based
    /// UTF-16 `column`).
    ///
    /// Continuation lines pick up the current line's indentation.
    /// When `trigger` is given and those characters really do sit
    /// immediately before the caret, they are replaced — that's the
    /// Tab path, where the user typed `routes` and expects it gone.
    static func apply(
        body: String,
        to source: String,
        line: Int,
        column: Int,
        replacingTrigger trigger: String? = nil
    ) -> Result? {
        let ns = source as NSString
        var lineStarts: [Int] = [0]
        for i in 0..<ns.length where ns.character(at: i) == 0x0A {
            lineStarts.append(i + 1)
        }
        guard line >= 1, line - 1 < lineStarts.count else { return nil }
        let lineStart = lineStarts[line - 1]
        let lineEnd = line < lineStarts.count ? lineStarts[line] - 1 : ns.length
        let caret = min(max(lineStart, lineStart + column), lineEnd)

        // Indentation of the line the caret sits on, copied onto
        // every continuation line of the snippet.
        var indentEnd = lineStart
        while indentEnd < lineEnd {
            let ch = ns.character(at: indentEnd)
            guard ch == 0x20 || ch == 0x09 else { break }
            indentEnd += 1
        }
        let indent = ns.substring(
            with: NSRange(location: lineStart, length: indentEnd - lineStart))

        let expansion = SnippetExpander.expand(body, indent: indent)

        var replaceRange = NSRange(location: caret, length: 0)
        if let trigger, !trigger.isEmpty {
            let triggerLength = (trigger as NSString).length
            let start = caret - triggerLength
            if start >= lineStart,
               ns.substring(with: NSRange(location: start, length: triggerLength))
                   .lowercased() == trigger.lowercased()
            {
                replaceRange = NSRange(location: start, length: triggerLength)
            }
        }

        let updated = ns.replacingCharacters(in: replaceRange, with: expansion.text)
        let selection = expansion.firstPlaceholder.map {
            NSRange(location: replaceRange.location + $0.location, length: $0.length)
        }
        return Result(
            text: updated,
            selection: selection,
            caretOffset: replaceRange.location + (expansion.text as NSString).length
        )
    }
}

// MARK: - Built-in library

extension AROSnippet {
    /// The patterns SOLARO ships with. Every body is parsed by
    /// `SnippetLibraryTests` — a snippet that doesn't compile is
    /// worse than no snippet, and shipping one is exactly the
    /// failure mode GitLab #486 was about.
    static let builtIns: [AROSnippet] = [
        AROSnippet(
            name: "Application-Start with HTTP server",
            summary: "Entry point that boots the contract-first server and stays alive.",
            trigger: "appstart",
            body: """
            (Application-Start: ${App Name}) {
                Log "Starting ${App Name}..." to the <console>.
                Start the <http-server> with { }.
                Keepalive the <application> for the <events>.
                Return an <OK: status> for the <startup>.
            }
            """,
            origin: .builtIn
        ),
        AROSnippet(
            name: "Route triple (list / create / get)",
            summary: "The three operationIds every resource starts with. Names must match openapi.yaml.",
            trigger: "routes",
            body: """
            (list${Entity}s: ${Entity} API) {
                Retrieve the <items> from the <${entity}-repository>.
                Return an <OK: status> with { items: <items> }.
            }

            (create${Entity}: ${Entity} API) {
                Extract the <data> from the <request: body>.
                Create the <${entity}> with <data>.
                Store the <${entity}> into the <${entity}-repository>.
                Emit a <${Entity}Created: event> with <${entity}>.
                Return a <Created: status> with <${entity}>.
            }

            (get${Entity}: ${Entity} API) {
                Extract the <id> from the <pathParameters: id>.
                Retrieve the <${entity}> from the <${entity}-repository> where <id> is <id>.
                Return an <OK: status> with <${entity}>.
            }
            """,
            origin: .builtIn
        ),
        AROSnippet(
            name: "Event emit + handler pair",
            summary: "A feature set that emits a domain event and the handler that reacts to it.",
            trigger: "event",
            body: """
            (${Feature Name}: ${Business Activity}) {
                Create the <payload> with { id: 1 }.
                Emit a <${EventName}: event> with <payload>.
                Return an <OK: status> for the <${EventName}>.
            }

            (Handle ${EventName}: ${EventName} Handler) {
                Extract the <id> from the <event: id>.
                Log <id> to the <console>.
                Return an <OK: status> for the <handling>.
            }
            """,
            origin: .builtIn
        ),
        AROSnippet(
            name: "Repository observer",
            summary: "Reacts to every store / update / delete on a repository.",
            trigger: "observer",
            body: """
            (${Observer Name}: ${entity}-repository Observer) {
                Extract the <changeType> from the <event: changeType>.
                Extract the <entityId> from the <event: entityId>.
                Compute the <message> from "[${entity}] " ++ <changeType> ++ " id=" ++ <entityId>.
                Log <message> to the <console>.
                Return an <OK: status> for the <observation>.
            }
            """,
            origin: .builtIn
        ),
        AROSnippet(
            name: "Guarded throw",
            summary: "Code carries the happy case; a guarded Throw is how the unhappy one leaves.",
            trigger: "throw",
            body: """
            Throw the <${ErrorType}> for the <${reason}> when <${value}> < 0.
            """,
            origin: .builtIn
        ),
    ]
}

// MARK: - Custom snippets on disk

/// Decoded shape of one `.solaro/snippets/*.yaml` file. Both a
/// top-level `snippets:` list and a bare list are accepted — the
/// bare form is what people write first.
enum SnippetFileDecoder {
    /// Parse one YAML document into snippets. Throws a message
    /// suitable for showing in the panel rather than an opaque
    /// Yams error, because the user is the author of the file.
    static func decode(yaml: String, fileName: String) throws -> [AROSnippet] {
        let loaded = try Yams.load(yaml: yaml)
        let rawList: [Any]
        if let dict = loaded as? [String: Any] {
            guard let list = dict["snippets"] as? [Any] else {
                throw SnippetError.message(
                    "\(fileName): expected a top-level `snippets:` list.")
            }
            rawList = list
        } else if let list = loaded as? [Any] {
            rawList = list
        } else if loaded == nil {
            return []
        } else {
            throw SnippetError.message(
                "\(fileName): expected a list of snippets or a `snippets:` key.")
        }

        return try rawList.enumerated().map { index, entry in
            guard let item = entry as? [String: Any] else {
                throw SnippetError.message(
                    "\(fileName): entry \(index + 1) is not a mapping.")
            }
            guard let name = item["name"] as? String, !name.isEmpty else {
                throw SnippetError.message(
                    "\(fileName): entry \(index + 1) has no `name`.")
            }
            guard let body = item["body"] as? String, !body.isEmpty else {
                throw SnippetError.message(
                    "\(fileName): \u{201C}\(name)\u{201D} has no `body`.")
            }
            let trigger = (item["trigger"] as? String ?? "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return AROSnippet(
                name: name,
                summary: item["description"] as? String ?? "",
                trigger: trigger,
                // Trailing newline from a YAML block scalar is an
                // artefact of the format, not of the snippet.
                body: body.hasSuffix("\n") ? String(body.dropLast()) : body,
                origin: .custom(fileName: fileName)
            )
        }
    }
}

enum SnippetError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

// MARK: - Library

@MainActor
@Observable
final class SnippetLibrary {
    /// Directory, relative to the project root, that holds custom
    /// snippet files.
    static let customDirectory = ".solaro/snippets"

    private(set) var builtIns: [AROSnippet] = AROSnippet.builtIns
    private(set) var custom: [AROSnippet] = []
    /// First problem hit while reading custom files. Surfaced in the
    /// panel — a snippet file that silently doesn't load is the kind
    /// of thing people debug for twenty minutes.
    private(set) var loadError: String?

    private var projectRoot: URL?

    init() {}

    var all: [AROSnippet] { custom + builtIns }

    /// Absolute path of the custom snippets directory for the open
    /// project, whether or not it exists yet.
    var customDirectoryURL: URL? {
        projectRoot?.appendingPathComponent(Self.customDirectory, isDirectory: true)
    }

    /// Re-read `.solaro/snippets/*.yaml`. Cheap enough to call on
    /// every project open and after the user creates the folder.
    func reload(projectRoot root: URL?) {
        projectRoot = root
        custom = []
        loadError = nil
        guard let dir = customDirectoryURL,
              FileManager.default.fileExists(atPath: dir.path)
        else { return }

        let files: [URL]
        do {
            files = try FileManager.default
                .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter {
                    let ext = $0.pathExtension.lowercased()
                    return ext == "yaml" || ext == "yml"
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            loadError = "Could not read \(Self.customDirectory): \(error.localizedDescription)"
            return
        }

        var collected: [AROSnippet] = []
        for file in files {
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                collected += try SnippetFileDecoder.decode(
                    yaml: text, fileName: file.lastPathComponent)
            } catch {
                // Report the first bad file but keep the good ones —
                // one typo shouldn't empty the whole panel.
                if loadError == nil {
                    loadError = error.localizedDescription
                }
            }
        }
        custom = collected
    }

    /// Snippet bound to `trigger`, custom taking precedence so a
    /// project can override a built-in without renaming it.
    func snippet(forTrigger trigger: String) -> AROSnippet? {
        let key = trigger.lowercased()
        guard !key.isEmpty else { return nil }
        return custom.first { $0.trigger == key }
            ?? builtIns.first { $0.trigger == key }
    }
}
