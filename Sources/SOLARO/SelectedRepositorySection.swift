// ============================================================
// SelectedRepositorySection.swift
// SOLARO — Inspector card for repository entities
// ============================================================
//
// Click a repository node on the canvas → this section pops up
// in the inspector with the live record table. The user can:
//   * Edit individual field values inline.
//   * Delete one row with the minus-circle button.
//   * Clear every row with the trailing "Clear all" button.
//
// The edits are UI-state mutations only — the next runtime run
// rebuilds the table from the actual flow of events / the seed
// data in the `.store` file. The `RepositoryStore` runtime API
// has clear/delete primitives (Sources/ARORuntime/Core/
// RepositoryStorage.swift) that we'll wire in when SOLARO grows
// a "send-edit-to-live-runtime" channel; until then the section
// gives the user a fast scratchpad on the canvas they're
// reading.

import SwiftUI

struct SelectedRepositorySection: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        if let repo = controller.selectedRepository {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                header(repo)
                tableBody(for: repo)
            }
            // Identity by repo name so SwiftUI resets the row
            // bindings whenever the user picks a different repo —
            // otherwise an in-flight edit on `users-repository`
            // would briefly bleed into the first row of
            // `orders-repository`.
            .id(repo.name)
        }
    }

    @ViewBuilder
    private func header(_ repo: RepositoryNode) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("SELECTED REPOSITORY")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
            Spacer()
            Button {
                controller.selectedRepository = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .buttonStyle(.borderless)
            .help("Close the repository inspector")
        }
        HStack(alignment: .firstTextBaseline, spacing: SolaroSpace.xs) {
            Image(systemName: "cylinder.split.1x2.fill")
                .foregroundStyle(SolaroColor.accent)
            Text(repo.name)
                .font(SolaroFont.bodyBold)
                .foregroundStyle(SolaroColor.textPrimary)
            Spacer()
            Text(rowCountLabel(for: repo))
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
    }

    private func rowCountLabel(for repo: RepositoryNode) -> String {
        let count = controller.repositoryRecords[repo.name]?.count ?? 0
        return "\(count) row\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func tableBody(for repo: RepositoryNode) -> some View {
        let rows = controller.repositoryRecords[repo.name] ?? []
        let columns = columnOrder(for: rows)
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            if rows.isEmpty {
                Text("(no entries — UI scratch)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, _ in
                    rowEditor(repo: repo,
                              rowIndex: idx,
                              columns: columns)
                    if idx < rows.count - 1 {
                        Divider().background(SolaroColor.divider)
                    }
                }
            }
            HStack {
                Spacer()
                Button(role: .destructive) {
                    controller.clearRepositoryEntries(named: repo.name)
                } label: {
                    Label("Clear all", systemImage: "trash")
                }
                .disabled(rows.isEmpty)
                .controlSize(.small)
            }
        }
        .padding(SolaroSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solaroCard()
    }

    @ViewBuilder
    private func rowEditor(
        repo: RepositoryNode,
        rowIndex: Int,
        columns: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Row \(rowIndex + 1)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
                Button {
                    controller.removeRepositoryEntry(
                        repository: repo.name,
                        at: rowIndex)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                .buttonStyle(.borderless)
                .help("Delete this entry")
            }
            ForEach(columns, id: \.self) { col in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(col)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .frame(width: 80, alignment: .trailing)
                    TextField(
                        col,
                        text: binding(
                            repo: repo.name,
                            row: rowIndex,
                            field: col)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(SolaroFont.mono)
                    .controlSize(.small)
                }
            }
        }
    }

    /// Two-way binding into one cell of the records dictionary.
    /// Getter pulls the current rendered value; setter writes back
    /// through `WorkspaceController.updateRepositoryEntry`, which
    /// keeps the rest of the dict (other rows, other repos)
    /// untouched.
    private func binding(repo: String, row: Int, field: String) -> Binding<String> {
        Binding(
            get: {
                guard let rows = controller.repositoryRecords[repo],
                      rows.indices.contains(row) else { return "" }
                return rows[row][field] ?? ""
            },
            set: { newValue in
                controller.updateRepositoryEntry(
                    repository: repo,
                    at: row,
                    field: field,
                    value: newValue)
            }
        )
    }

    /// Stable column ordering — same logic as `RepoCard`, repeated
    /// here so we can sort `rows` deterministically across redraws
    /// without dragging a dependency on RepoCard's private type.
    private func columnOrder(for rows: [[String: String]]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for row in rows {
            for key in row.keys where !seen.contains(key) {
                seen.insert(key)
                out.append(key)
            }
        }
        return out.sorted()
    }
}

