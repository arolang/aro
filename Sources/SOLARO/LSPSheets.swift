// ============================================================
// LSPSheets.swift
// SOLARO — small sheets for rename + blame
// ============================================================

import SwiftUI

struct RenameSheet: View {
    @Binding var newName: String
    @Binding var error: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

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
                .onSubmit(onConfirm)
            if let error {
                Text(error)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.stateError)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
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
