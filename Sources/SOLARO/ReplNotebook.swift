// ============================================================
// ReplNotebook.swift
// SOLARO — .repl notebook document model
// ============================================================
//
// A `.repl` file is a notebook: markdown prose cells and ARO code
// cells with their captured outputs, executed against the same
// `aro repl --json` server the Jupyter kernel drives (ARO-0091).
// The file format is JSON — structurally a small cousin of
// `.ipynb`, but with ARO's display bundle kept as first-class
// fields instead of a MIME dictionary, so the file stays readable
// in a diff.
//
// Pure value types — no SwiftUI — so encode/decode round-trips are
// unit-testable without a view hierarchy. The live editing state
// (selection, kernel, run queue) lives in `ReplNotebookController`.

import Foundation

// MARK: - File-type routing

enum ReplFile {
    /// Extension the notebook editor claims.
    static let fileExtension = "repl"

    static func isNotebook(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }
}

// MARK: - Cells

/// One captured output of a code cell, in arrival order. `stream`
/// entries interleave exactly as the server emitted them; a cell
/// ends with at most one `result` or one `error` (the protocol
/// answers every execute with exactly one result message).
struct ReplCellOutput: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case stream
        case result
        case error
    }

    var kind: Kind

    // --- stream ---
    /// "stdout" / "stderr" for `stream` outputs.
    var streamName: String?
    var text: String?

    // --- result (display bundle, ARO-0091 §Display bundles) ---
    /// `text/plain` — always present on a displayed value.
    var plainText: String?
    /// `application/json` re-serialized as a JSON string, when the
    /// value encoded. Drives the native table rendering.
    var jsonValue: String?

    // --- error ---
    var errorName: String?
    var errorValue: String?
    var traceback: [String]?

    static func stream(name: String, text: String) -> ReplCellOutput {
        ReplCellOutput(kind: .stream, streamName: name, text: text)
    }

    static func result(plainText: String?, jsonValue: String?) -> ReplCellOutput {
        ReplCellOutput(kind: .result, plainText: plainText, jsonValue: jsonValue)
    }

    static func error(name: String, value: String, traceback: [String]) -> ReplCellOutput {
        ReplCellOutput(kind: .error, errorName: name, errorValue: value,
                       traceback: traceback)
    }
}

/// One notebook cell. Identity is a UUID string so cells keep
/// their SwiftUI identity across reorder / retype, and so two
/// checkouts of the same file don't collide ids.
struct ReplNotebookCell: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case markdown
        case code
    }

    var id: String
    var kind: Kind
    var source: String
    /// Captured outputs of the last run (code cells only).
    var outputs: [ReplCellOutput]
    /// The session-order counter at the time the cell last ran —
    /// the `[3]` badge. Nil for never-run cells.
    var executionCount: Int?
    /// Server-reported execution time of the last run.
    var durationMs: Double?

    init(id: String = UUID().uuidString,
         kind: Kind,
         source: String = "",
         outputs: [ReplCellOutput] = [],
         executionCount: Int? = nil,
         durationMs: Double? = nil) {
        self.id = id
        self.kind = kind
        self.source = source
        self.outputs = outputs
        self.executionCount = executionCount
        self.durationMs = durationMs
    }

    /// Decode, defaulting what is *absent* and refusing what is wrong.
    ///
    /// The two cases look similar and are not. A hand-written notebook
    /// that omits `outputs` has simply never been run, and defaulting it
    /// to empty is right — the original intent of this initialiser, and
    /// the reason `.repl` files are pleasant to edit by hand. A cell
    /// whose `source` is a number, or whose `kind` is a word that is not
    /// a kind, is damaged, and the old code turned it into an empty code
    /// cell with a freshly minted identity (#760). The 800 ms autosave
    /// then wrote that back, so the cell's contents and its identity
    /// were gone permanently, without a word. The Learning course ships
    /// as `.repl` files that users edit, so this is a real path.
    ///
    /// `decodeIfPresent` draws exactly that line: `nil` for a key that
    /// is absent or null, and a thrown error for one that is present and
    /// of the wrong shape. The error reaches `ReplNotebookDocument.load`,
    /// which surfaces it as `loadError` — and `saveNow` refuses to write
    /// while that is set, so nothing overwrites the damaged file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A missing id costs nothing: there is no identity to lose, and
        // one is needed for SwiftUI to track the row.
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? UUID().uuidString
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .code
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        outputs = try c.decodeIfPresent([ReplCellOutput].self,
                                        forKey: .outputs) ?? []
        executionCount = try c.decodeIfPresent(Int.self,
                                               forKey: .executionCount)
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
    }
}

// MARK: - Document

/// The `.repl` file: a versioned list of cells.
struct ReplNotebookDocument: Codable, Equatable, Sendable {
    /// Format version. Bump on breaking shape changes; the decoder
    /// refuses versions it doesn't know rather than mis-reading.
    static let currentVersion = 1

    var version: Int
    var cells: [ReplNotebookCell]

    init(cells: [ReplNotebookCell] = []) {
        self.version = Self.currentVersion
        self.cells = cells
    }

    /// A fresh notebook: a heading to explain, a code cell to run.
    static func starter(named name: String) -> ReplNotebookDocument {
        ReplNotebookDocument(cells: [
            ReplNotebookCell(kind: .markdown,
                             source: "# \(name)\n\nAn ARO notebook. Markdown cells hold prose; code cells run against a live `aro` REPL session — definitions accumulate from cell to cell."),
            ReplNotebookCell(kind: .code,
                             source: "Compute the <greeting: uppercase> from \"hello, aro\"."),
        ])
    }

    // MARK: Serialization

    enum LoadError: Error, LocalizedError {
        case unsupportedVersion(Int)
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "This notebook was saved by a newer SOLARO (format version \(v)). Update SOLARO to open it."
            }
        }
    }

    static func load(from url: URL) throws -> ReplNotebookDocument {
        let data = try Data(contentsOf: url)
        // An empty file is a valid brand-new notebook — `touch
        // scratch.repl` should open, not error.
        if data.isEmpty { return ReplNotebookDocument() }
        let doc = try JSONDecoder().decode(ReplNotebookDocument.self, from: data)
        guard doc.version <= currentVersion else {
            throw LoadError.unsupportedVersion(doc.version)
        }
        return doc
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // Stable key order + pretty printing so the file diffs like
        // source, not like a minified blob.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func save(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}
