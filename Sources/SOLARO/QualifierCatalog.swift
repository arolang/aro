// ============================================================
// QualifierCatalog.swift
// SOLARO — dropdown source for the node editor's Modifier picker
// ============================================================
//
// The node editor's "Modifier" field offers a dropdown of every
// known qualifier (plus a free-text fallback) so a user editing
// `<user: uppercase>` can pick from `uppercase`, `lowercase`,
// `hash`, `collections.reverse`, … without typing it from
// memory. The list is *dynamic*: we read it from the runtime's
// `QualifierRegistry` so plugin-registered qualifiers light up
// automatically the first time their plugin loads.

import Foundation
import ARORuntime

/// A single dropdown entry. `value` is what gets written into the
/// source (`uppercase`, `collections.reverse`), `label` is the
/// human-friendly menu line (`uppercase — Convert to UPPERCASE`).
struct QualifierOption: Identifiable, Hashable {
    let id: String
    let value: String
    let label: String
}

enum QualifierCatalog {

    /// Snapshot every registered qualifier into a sorted list of
    /// `QualifierOption`s. Built-ins (`_builtin.uppercase` etc.)
    /// drop the namespace prefix because the user types them
    /// without it; plugin qualifiers keep the namespace so the
    /// dropdown distinguishes between `collections.reverse` and
    /// any future `stats.reverse`. Returns alphabetised by label
    /// so duplicates from re-registration (a plugin reload) don't
    /// reorder the menu.
    static func snapshot() -> [QualifierOption] {
        let regs = QualifierRegistry.shared.allRegistrations()
        var seen: Set<String> = []
        var out: [QualifierOption] = []
        for r in regs {
            let value: String
            if r.namespace == "_builtin" {
                value = r.qualifier
            } else {
                value = "\(r.namespace).\(r.qualifier)"
            }
            guard !seen.contains(value) else { continue }
            seen.insert(value)
            let label: String
            if let d = r.description, !d.isEmpty {
                label = "\(value) — \(d)"
            } else {
                label = value
            }
            out.append(QualifierOption(
                id: value, value: value, label: label
            ))
        }
        return out.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
    }
}
