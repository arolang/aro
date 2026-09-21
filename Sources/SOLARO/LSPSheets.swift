// ============================================================
// LSPSheets.swift
// SOLARO — small sheets for rename + blame
// ============================================================

import SwiftUI

/// What a rename is about to do, grouped by file (#764).
struct RenamePreview: Equatable {
    struct File: Identifiable, Equatable {
        let url: URL
        let edits: Int
        var id: String { url.path }
        var label: String {
            "\(url.lastPathComponent) — \(edits) "
                + (edits == 1 ? "occurrence" : "occurrences")
        }
    }

    let files: [File]

    var isEmpty: Bool { files.isEmpty }
    var totalEdits: Int { files.reduce(0) { $0 + $1.edits } }

    var summary: String {
        let occurrences = totalEdits == 1 ? "1 occurrence" : "\(totalEdits) occurrences"
        let fileCount = files.count == 1 ? "1 file" : "\(files.count) files"
        return "\(occurrences) in \(fileCount)"
    }

    /// Group a flat edit list the way a reader wants to check it.
    init(edits: [AROLSPClient.TextEdit]) {
        var counts: [URL: Int] = [:]
        for edit in edits {
            counts[edit.url.standardizedFileURL, default: 0] += 1
        }
        files = counts
            .map { File(url: $0.key, edits: $0.value) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
}

struct RenameSheet: View {
    @Binding var newName: String
    @Binding var error: String?
    /// `nil` until the user asks what the rename would do.
    let preview: RenamePreview?
    let onCancel: () -> Void
    let onPreview: () -> Void
    let onConfirm: () -> Void

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            HStack(spacing: SolaroSpace.s) {
                Image(systemName: "character.cursor.ibeam")
                    .foregroundStyle(SolaroColor.accent)
                Text("Rename symbol")
                    .font(SolaroFont.toolbarTitle)
                Spacer()
            }
            Text("Type the new identifier. The LSP server applies the rename across every file that references it.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
            TextField("new-name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onPreview)
            if let error {
                Text(error)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.stateError)
            }

            // What the rename will touch, before it touches it (#764).
            // A rename used to apply a whole workspace edit sight
            // unseen — across every file, with only undo to fall back
            // on, and no way to notice that it had reached somewhere
            // unintended.
            if let preview {
                Divider()
                if preview.isEmpty {
                    Text("Nothing to rename here.")
                        .font(SolaroFont.caption)
                        .foregroundStyle(SolaroColor.textTertiary)
                } else {
                    Text(preview.summary)
                        .font(SolaroFont.caption)
                        .foregroundStyle(SolaroColor.textSecondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(preview.files) { file in
                                Text(file.label)
                                    .font(SolaroFont.monoCaption)
                                    .foregroundStyle(SolaroColor.textPrimary)
                                    .frame(maxWidth: .infinity,
                                           alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if preview == nil {
                    Button("Preview…", action: onPreview)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedName.isEmpty)
                } else {
                    Button("Rename", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedName.isEmpty
                                  || preview?.isEmpty == true)
                }
            }
        }
        .padding(SolaroSpace.l)
        .frame(minWidth: 420)
        .background(SolaroColor.surface)
    }
}

struct BlameSheet: View {
    let content: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            HStack {
                Image(systemName: "scroll")
                    .foregroundStyle(SolaroColor.accent)
                Text("Git blame")
                    .font(SolaroFont.toolbarTitle)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(content)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SolaroSpace.s)
            }
            .background(SolaroColor.backdrop)
            .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
        }
        .padding(SolaroSpace.l)
        .frame(minWidth: 720, minHeight: 480)
        .background(SolaroColor.surface)
    }
}
