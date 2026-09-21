// ============================================================
// StoreFileView.swift
// SOLARO — editing a `.store` file as a table (#766)
// ============================================================
//
// Shown in the canvas pane for a `.store` file, the way the OpenAPI
// graph is shown for `openapi.yaml`. The text pane still opens the same
// file, so anything this editor cannot express stays reachable.

import SwiftUI

struct StoreFileView: View {
    let url: URL
    /// The file's text, and where an edit goes back to.
    @Binding var text: String

    @State private var newColumnName = ""

    private var store: StoreFile? { StoreFile.parse(text) }

    var body: some View {
        if let store {
            table(store)
        } else {
            unrepresentable
        }
    }

    // MARK: - Table

    private func table(_ store: StoreFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(store)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    columnHeader(store)
                    ForEach(Array(store.rows.indices), id: \.self) { index in
                        row(index, of: store)
                    }
                }
                .padding(SolaroSpace.s)
            }
        }
        .background(SolaroColor.backdrop)
    }

    private func header(_ store: StoreFile) -> some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "tablecells")
                .foregroundStyle(SolaroColor.accent)
            Text(url.lastPathComponent)
                .font(SolaroFont.bodyBold)
            // ARO-0073 makes writability a permission, and it explains
            // why a Store action did or did not persist — so say it
            // rather than leaving the user to run `ls -l`.
            Text(StoreFile.isWritable(at: url)
                 ? "writable repository"
                 : "read-only seed data")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer()
            Text("\(store.rows.count) "
                 + (store.rows.count == 1 ? "row" : "rows"))
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            Button {
                mutate { $0.addRow() }
            } label: {
                Label("Add Row", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .help("Append an empty row")
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.xs)
        .background(SolaroColor.surface)
    }

    private func columnHeader(_ store: StoreFile) -> some View {
        HStack(spacing: SolaroSpace.xs) {
            Text("")
                .frame(width: 24)
            ForEach(store.columns, id: \.self) { column in
                HStack(spacing: 2) {
                    Text(column)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                    Button {
                        mutate { $0.removeColumn(named: column) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .help("Remove the \(column) column and every value in it")
                }
                .frame(width: 140, alignment: .leading)
            }
            TextField("new column", text: $newColumnName)
                .textFieldStyle(.roundedBorder)
                .font(SolaroFont.monoCaption)
                .frame(width: 120)
                .onSubmit {
                    mutate { $0.addColumn(named: newColumnName) }
                    newColumnName = ""
                }
        }
        .padding(.bottom, SolaroSpace.xs)
    }

    private func row(_ index: Int, of store: StoreFile) -> some View {
        HStack(spacing: SolaroSpace.xs) {
            Button {
                mutate { $0.removeRow(at: index) }
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(SolaroColor.textTertiary)
            .frame(width: 24)
            .help("Delete this row")

            ForEach(store.columns, id: \.self) { column in
                TextField("", text: Binding(
                    get: { store.rows[index][column] ?? "" },
                    set: { value in
                        mutate { $0.setValue(value, row: index, column: column) }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(SolaroFont.mono)
                .frame(width: 140)
            }
        }
        .padding(.vertical, 1)
    }

    /// A store file whose YAML is not a sequence of flat mappings.
    ///
    /// Rather than mangle it, say so and leave the text pane to it.
    private var unrepresentable: some View {
        VStack(spacing: SolaroSpace.s) {
            Image(systemName: "tablecells.badge.ellipsis")
                .font(.system(size: 28))
                .foregroundStyle(SolaroColor.textTertiary)
            Text("This store file isn't a table")
                .font(SolaroFont.bodyBold)
            Text("ARO-0073 store files are a YAML list of flat records. "
                 + "This one is something else, so it opens in the text "
                 + "editor instead.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SolaroColor.backdrop)
    }

    /// Apply an edit and write the file back through the binding.
    ///
    /// Re-parsing on every keystroke rather than holding a model: the
    /// text is the document, the editor and this table are two views of
    /// it, and a second copy of the truth is how they drift apart.
    private func mutate(_ change: (inout StoreFile) -> Void) {
        guard var store = StoreFile.parse(text) else { return }
        change(&store)
        text = store.serialized()
    }
}
