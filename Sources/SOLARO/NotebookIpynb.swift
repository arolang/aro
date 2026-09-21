// ============================================================
// NotebookIpynb.swift
// SOLARO — `.repl` ↔ `.ipynb` (#769)
// ============================================================
//
// The book positions notebooks as the Jupyter-parity surface and as the
// data-engineering deliverable, and ARO ships a real Jupyter kernel
// (ARO-0091). Exchanging a notebook with somebody who lives in
// JupyterLab needs the format JupyterLab reads, and there was no export
// and no import.
//
// This is nbformat 4.5, the version JupyterLab has written since 2021.
// Only the parts a `.repl` has: cells, sources, outputs, an execution
// count and the kernel metadata that makes Jupyter pick the ARO kernel
// rather than asking.
//
// Two deliberate asymmetries. Export renders a `.repl`'s display bundle
// into nbformat's `data` shape; import reads `text/plain` back and
// drops richer mime types it has nowhere to put, which is why an
// import is not advertised as lossless. And `source` is a list of
// lines with their newlines kept, because that is what nbformat says
// and it is what makes an `.ipynb` diff line by line.

import Foundation

enum NotebookIpynb {

    /// nbformat major/minor. 4.5 is what current JupyterLab writes.
    static let formatMajor = 4
    static let formatMinor = 5

    // MARK: - Export

    static func export(_ document: ReplNotebookDocument) throws -> Data {
        let notebook: [String: Any] = [
            "nbformat": formatMajor,
            "nbformat_minor": formatMinor,
            "metadata": [
                // Without this, opening the file asks which kernel to
                // use, every time.
                "kernelspec": [
                    "name": "aro",
                    "display_name": "ARO",
                    "language": "aro",
                ],
                "language_info": [
                    "name": "aro",
                    "file_extension": ".aro",
                ],
            ],
            "cells": document.cells.map(cell(from:)),
        ]
        return try JSONSerialization.data(
            withJSONObject: notebook,
            options: [.prettyPrinted, .sortedKeys])
    }

    private static func cell(from cell: ReplNotebookCell) -> [String: Any] {
        var out: [String: Any] = [
            "cell_type": cell.kind == .markdown ? "markdown" : "code",
            "metadata": [:],
            "source": sourceLines(cell.source),
            // nbformat 4.5 gives every cell a stable id, which is what
            // makes a notebook diff rather than re-write.
            "id": cell.id,
        ]
        if cell.kind == .code {
            out["execution_count"] = cell.executionCount as Any? ?? NSNull()
            out["outputs"] = cell.outputs.map(output(from:))
        }
        return out
    }

    private static func output(from output: ReplCellOutput) -> [String: Any] {
        switch output.kind {
        case .stream:
            return [
                "output_type": "stream",
                "name": output.streamName ?? "stdout",
                "text": sourceLines(output.text ?? ""),
            ]
        case .result:
            var data: [String: Any] = [
                "text/plain": sourceLines(output.plainText ?? ""),
            ]
            // A JSON display bundle travels as application/json, which
            // JupyterLab renders as a collapsible tree.
            if let json = output.jsonValue,
               let parsed = try? JSONSerialization.jsonObject(
                   with: Data(json.utf8)) {
                data["application/json"] = parsed
            }
            return [
                "output_type": "execute_result",
                "execution_count": NSNull(),
                "metadata": [:],
                "data": data,
            ]
        case .error:
            return [
                "output_type": "error",
                "ename": output.errorName ?? "Error",
                "evalue": output.errorValue ?? "",
                "traceback": output.traceback ?? [],
            ]
        }
    }

    /// nbformat stores text as a list of lines with their newlines
    /// kept. Keeping them is what makes an `.ipynb` diff line by line
    /// instead of as one long string.
    static func sourceLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "\n" {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    // MARK: - Import

    enum ImportError: Error, LocalizedError {
        case notANotebook
        case unsupportedFormat(Int)

        var errorDescription: String? {
            switch self {
            case .notANotebook:
                return "That file isn't a Jupyter notebook."
            case .unsupportedFormat(let major):
                return "nbformat \(major) isn't supported — SOLARO reads version 4."
            }
        }
    }

    /// Read an `.ipynb` into the `.repl` model.
    ///
    /// Not lossless, and deliberately not described as such: nbformat
    /// carries mime bundles, attachments and per-cell metadata that a
    /// `.repl` has nowhere to put, and they are dropped rather than
    /// half-represented.
    static func importNotebook(_ data: Data) throws -> ReplNotebookDocument {
        guard let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw ImportError.notANotebook
        }
        guard let major = root["nbformat"] as? Int else {
            throw ImportError.notANotebook
        }
        guard major == 4 else { throw ImportError.unsupportedFormat(major) }
        let rawCells = root["cells"] as? [[String: Any]] ?? []

        var cells: [ReplNotebookCell] = []
        for raw in rawCells {
            let type = raw["cell_type"] as? String ?? "code"
            // A raw cell has no equivalent and is not code; treat it as
            // markdown so its text survives rather than being run.
            let kind: ReplNotebookCell.Kind = (type == "code") ? .code : .markdown
            cells.append(ReplNotebookCell(
                id: (raw["id"] as? String) ?? UUID().uuidString,
                kind: kind,
                source: joined(raw["source"]),
                outputs: (raw["outputs"] as? [[String: Any]] ?? [])
                    .compactMap(output(fromIpynb:)),
                executionCount: raw["execution_count"] as? Int
            ))
        }
        return ReplNotebookDocument(cells: cells)
    }

    private static func output(fromIpynb raw: [String: Any]) -> ReplCellOutput? {
        switch raw["output_type"] as? String {
        case "stream":
            return ReplCellOutput(
                kind: .stream,
                streamName: raw["name"] as? String ?? "stdout",
                text: joined(raw["text"]))
        case "execute_result", "display_data":
            let data = raw["data"] as? [String: Any] ?? [:]
            var json: String?
            if let value = data["application/json"],
               let encoded = try? JSONSerialization.data(
                   withJSONObject: value, options: [.sortedKeys]) {
                json = String(data: encoded, encoding: .utf8)
            }
            return ReplCellOutput(
                kind: .result,
                plainText: joined(data["text/plain"]),
                jsonValue: json)
        case "error":
            return ReplCellOutput(
                kind: .error,
                errorName: raw["ename"] as? String ?? "Error",
                errorValue: raw["evalue"] as? String ?? "",
                traceback: raw["traceback"] as? [String] ?? [])
        default:
            return nil
        }
    }

    /// nbformat allows either a string or a list of lines for any text
    /// field, and real notebooks in the wild contain both.
    static func joined(_ value: Any?) -> String {
        if let list = value as? [String] { return list.joined() }
        if let string = value as? String { return string }
        return ""
    }
}
