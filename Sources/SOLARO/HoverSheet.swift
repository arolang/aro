// ============================================================
// HoverSheet.swift
// SOLARO — display the LSP hover response for the current caret
// ============================================================
//
// Triggered via ⌃⌘H or the command palette. Renders whatever
// `textDocument/hover` produced: usually a Markdown-ish blob
// describing the symbol under the caret. We don't render full
// Markdown — the server's text is shown as-is in a monospaced
// box, which is plenty for type signatures + brief descriptions.

import SwiftUI

@MainActor
@Observable
final class HoverSheetState {
    var content: String = ""
    var isLoading: Bool = false
    var hasResult: Bool = false
    var symbol: String?
}

struct HoverSheet: View {
    @Bindable var state: HoverSheetState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            HStack(spacing: SolaroSpace.s) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(SolaroColor.accent)
                Text(state.symbol.map { "Hover · \($0)" } ?? "Hover at caret")
                    .font(SolaroFont.toolbarTitle)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            Divider()
            content
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SolaroSpace.l)
        .frame(minWidth: 480, minHeight: 240)
        .background(SolaroColor.surface)
    }

    @ViewBuilder
    private var content: some View {
        if state.isLoading {
            HStack(spacing: SolaroSpace.s) {
                ProgressView().controlSize(.small)
                Text("Asking `aro lsp` for hover info…")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .padding()
        } else if state.hasResult && !state.content.isEmpty {
            ScrollView {
                Text(state.content)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SolaroSpace.s)
            }
            .background(SolaroColor.backdrop)
            .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
        } else if state.hasResult {
            Text("No hover info available for this position.")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
                .padding()
        }
    }
}
