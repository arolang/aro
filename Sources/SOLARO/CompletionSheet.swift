// ============================================================
// CompletionSheet.swift
// SOLARO — pick a completion from `aro lsp` at the caret (#254)
// ============================================================
//
// Triggered via ⌃Space or the command palette. Sends
// `textDocument/completion` and renders the result as a
// keyboard-navigable list. Picking an item inserts its
// insertText at the caret position.

import SwiftUI
import AppKit

@MainActor
@Observable
final class CompletionSheetState {
    var items: [AROLSPClient.CompletionItem] = []
    var isLoading: Bool = false
    var hasResult: Bool = false
    /// Currently focused row — drives keyboard navigation.
    var selection: AROLSPClient.CompletionItem.ID?
}

struct CompletionSheet: View {
    @Bindable var state: CompletionSheetState
    let onPick: (AROLSPClient.CompletionItem) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            HStack(spacing: SolaroSpace.s) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(SolaroColor.accent)
                Text(state.isLoading ? "Resolving completions…"
                                     : "\(state.items.count) suggestion\(state.items.count == 1 ? "" : "s")")
                    .font(SolaroFont.sectionTitle)
                    .tracking(2)
                    .foregroundStyle(SolaroColor.textSecondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            Divider()
            content
        }
        .padding(SolaroSpace.l)
        .frame(minWidth: 460, minHeight: 320)
        .background(SolaroColor.surface)
        .onAppear { if state.selection == nil { state.selection = state.items.first?.id } }
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { commit(); return .handled }
        .onKeyPress(.tab) { commit(); return .handled }
    }

    @ViewBuilder
    private var content: some View {
        if state.isLoading {
            HStack(spacing: SolaroSpace.s) {
                ProgressView().controlSize(.small)
                Text("`aro lsp` is computing suggestions…")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, SolaroSpace.m)
        } else if state.items.isEmpty {
            Text("Nothing to suggest at this position.")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
                .padding(.vertical, SolaroSpace.m)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.items) { item in
                            row(item)
                                .id(item.id)
                        }
                    }
                }
                .frame(maxHeight: 380)
                .onChange(of: state.selection) { _, new in
                    guard let new else { return }
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private func row(_ item: AROLSPClient.CompletionItem) -> some View {
        let selected = state.selection == item.id
        return Button {
            state.selection = item.id
            commit()
        } label: {
            HStack(spacing: SolaroSpace.s) {
                Image(systemName: symbol(for: item.kind))
                    .foregroundStyle(color(for: item.kind))
                    .frame(width: 18)
                Text(item.label)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, SolaroSpace.s)
            .padding(.vertical, 4)
            .background(selected ? SolaroColor.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
        }
        .buttonStyle(.plain)
    }

    private func moveSelection(by delta: Int) {
        guard !state.items.isEmpty else { return }
        let index = state.items.firstIndex { $0.id == state.selection } ?? 0
        let next = max(0, min(state.items.count - 1, index + delta))
        state.selection = state.items[next].id
    }

    private func commit() {
        guard let id = state.selection,
              let item = state.items.first(where: { $0.id == id })
        else { return }
        onPick(item)
    }

    private func symbol(for kind: AROLSPClient.CompletionItem.Kind) -> String {
        switch kind {
        case .keyword:       return "key.fill"
        case .variable:      return "diamond.fill"
        case .function, .method: return "function"
        case .property, .field: return "circle.grid.cross.fill"
        case .module:        return "shippingbox"
        case .snippet:       return "scissors"
        case .constant, .value: return "number"
        case .reference:     return "link"
        default:             return "circle.fill"
        }
    }

    private func color(for kind: AROLSPClient.CompletionItem.Kind) -> Color {
        switch kind {
        case .keyword:       return SolaroColor.accent
        case .variable:      return SolaroColor.roleOwn
        case .function, .method: return SolaroColor.roleRequest
        case .property, .field: return SolaroColor.roleResponse
        case .snippet:       return SolaroColor.stateWarn
        default:             return SolaroColor.textTertiary
        }
    }
}
