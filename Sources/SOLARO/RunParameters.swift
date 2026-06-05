// ============================================================
// RunParameters.swift
// SOLARO — pre-run parameter dialog (CLI args via UI)
// ============================================================
//
// ARO programs read command-line parameters with
// `Extract the <x> from the <parameter: name>` (ARO-0047). When a
// user runs a project from SOLARO via the toolbar's Play button
// the runtime has no argv to read from, so referenced parameters
// resolve to nil and the program fails with
// `Cannot extract the <x> from the <parameter: name>`.
//
// Before launching a run we scan the project's parsed programs
// for `<parameter: NAME>` references. If any are referenced, a
// sheet pops up asking the user for values (pre-filled from the
// last successful run for this project). Hitting Execute saves
// the values and starts the run; the embedded path injects them
// into `ParameterStorage.shared`, the subprocess path appends
// `--name value` pairs to the `aro run` argv.

import Foundation
import SwiftUI
import AROParser

// MARK: - Scanner

/// Walks every `AROStatement` in every program for a project and
/// collects the set of `<parameter: NAME>` names it references.
/// The result is ordered by first-seen order so the dialog shows
/// fields in source order rather than alphabetically.
enum RunParameterScanner {

    static func scan(programs: [URL: Program]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for (_, program) in programs {
            for fs in program.featureSets {
                walk(fs.statements, seen: &seen, ordered: &ordered)
            }
        }
        return ordered
    }

    private static func walk(
        _ statements: [Statement],
        seen: inout Set<String>,
        ordered: inout [String]
    ) {
        for stmt in statements {
            if let aro = stmt as? AROStatement {
                if aro.object.noun.base == "parameter",
                   let name = aro.object.noun.specifiers.first,
                   !name.isEmpty,
                   !seen.contains(name) {
                    seen.insert(name)
                    ordered.append(name)
                }
                continue
            }
            if let loop = stmt as? ForEachLoop {
                walk(loop.body, seen: &seen, ordered: &ordered)
            } else if let loop = stmt as? WhileLoop {
                walk(loop.body, seen: &seen, ordered: &ordered)
            } else if let loop = stmt as? RangeLoop {
                walk(loop.body, seen: &seen, ordered: &ordered)
            } else if let match = stmt as? MatchStatement {
                for caseClause in match.cases {
                    walk(caseClause.body, seen: &seen, ordered: &ordered)
                }
                if let otherwise = match.otherwise {
                    walk(otherwise, seen: &seen, ordered: &ordered)
                }
            } else if let pipeline = stmt as? PipelineStatement {
                walk(pipeline.stages, seen: &seen, ordered: &ordered)
            }
        }
    }
}

// MARK: - Persistence

/// Per-project storage of the last-used parameter values so the
/// dialog can pre-fill them. Lives next to `recents.json` under
/// SOLARO's Application Support directory (ADR-007: strictly
/// local).
enum RunParameterDefaults {

    private static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SOLARO/parameters")
    }

    /// File path keyed by a hash of the project root so two
    /// projects with the same display name don't collide.
    private static func fileURL(for project: Project) -> URL {
        let key = projectKey(project)
        return directory.appendingPathComponent("\(key).json")
    }

    private static func projectKey(_ project: Project) -> String {
        let path = project.rootPath.standardizedFileURL.path
        // Cheap deterministic hash — collision risk is fine here,
        // worst case a different project's defaults appear and the
        // user edits them once.
        var h: UInt64 = 1469598103934665603
        for byte in path.utf8 {
            h ^= UInt64(byte)
            h &*= 1099511628211
        }
        return String(h, radix: 16)
    }

    static func load(for project: Project) -> [String: String] {
        guard
            let data = try? Data(contentsOf: fileURL(for: project)),
            let dict = try? JSONDecoder()
                .decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    static func save(_ values: [String: String], for project: Project) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(values) else { return }
        try? data.write(to: fileURL(for: project), options: [.atomic])
    }
}

// MARK: - Sheet

/// The Run-with-parameters dialog. One TextField per scanned
/// parameter, pre-filled from `RunParameterDefaults`. The buttons
/// are intentionally non-destructive: Cancel just dismisses, the
/// run doesn't start until the user clicks Execute.
struct RunParametersSheet: View {
    let parameters: [String]
    let project: Project
    let onCancel: () -> Void
    let onExecute: ([String: String]) -> Void

    @State private var values: [String: String]

    init(parameters: [String],
         project: Project,
         onCancel: @escaping () -> Void,
         onExecute: @escaping ([String: String]) -> Void) {
        self.parameters = parameters
        self.project = project
        self.onCancel = onCancel
        self.onExecute = onExecute
        let defaults = RunParameterDefaults.load(for: project)
        var initial: [String: String] = [:]
        for name in parameters { initial[name] = defaults[name] ?? "" }
        _values = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            header
            Divider()
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                ForEach(parameters, id: \.self) { name in
                    fieldRow(name: name)
                }
            }
            footer
        }
        .padding(SolaroSpace.l)
        .frame(width: 460)
        .background(SolaroColor.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Run \(project.displayName)")
                .font(SolaroFont.bodyBold)
                .foregroundStyle(SolaroColor.textPrimary)
            Text("This project reads command-line parameters. Fill in the values and click Execute.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldRow(name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name.uppercased())
                .font(SolaroFont.caption)
                .tracking(1)
                .foregroundStyle(SolaroColor.textTertiary)
            TextField("--\(name)", text: Binding(
                get: { values[name] ?? "" },
                set: { values[name] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.regular)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Execute") {
                RunParameterDefaults.save(values, for: project)
                onExecute(values)
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
