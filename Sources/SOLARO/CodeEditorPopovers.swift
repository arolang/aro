// ============================================================
// CodeEditorPopovers.swift
// SOLARO — hover-value + ghost-text overlays for the editor
// ============================================================
//
// Extracted from CodeEditor.swift (#285 step 1). The popovers
// stand on their own — they don't touch the editor's mutable
// state, only render symbol previews and ghost completions
// driven by callbacks the editor passes in.

import SwiftUI
import AppKit

struct HoverValuePopover: View {
    let symbol: ConsoleProcess.SymbolValue

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(SolaroColor.stateWarn)
                    .font(.system(size: 11))
                Text(symbol.name)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.accent)
                Text(":")
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textTertiary)
                Text(symbol.typeName)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("= ")
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textTertiary)
                Text(symbol.value)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .textSelection(.enabled)
            }
            Text("captured at the current pause")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
        .frame(maxWidth: 380, alignment: .leading)
    }
}

/// Multi-line read-only label backed by NSTextField so the text
/// is reliably mouse-selectable inside NSPopover contexts where
/// SwiftUI's `.textSelection(.enabled)` doesn't activate.
struct SelectableMonoText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.allowsEditingTextAttributes = false
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = NSColor(SolaroColor.textPrimary)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }
}

/// LSP-driven dropdown shown after a typing pause (#272).
/// Sits in an NSPopover anchored under the caret rect. Lists the
/// completion items returned by the LSP, with arrow-key navigation
/// once the user presses Tab. An optional AI section appears at
/// the top once the popover has been open ~1s and the
/// `solaro.editor.aiFallback` setting is on.
struct GhostTextPopover: View {
    @Bindable var state: GhostState
    let onAccept: (AROLSPClient.CompletionItem) -> Void
    let onAcceptAI: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if state.aiLoading || state.aiSuggestion != nil {
                aiSection
                Divider().background(SolaroColor.divider)
            }
            itemsList
            Divider().background(SolaroColor.divider)
            footer
        }
        // Fixed width so the SwiftUI host reports a non-zero
        // intrinsicContentSize — macOS 26's layout pass asserts on
        // 0×N popovers.
        .frame(width: 380, height: 280)
        .background(SolaroColor.surface)
    }

    // MARK: - AI section

    private var aiSection: some View {
        let selected = state.selectedIndex == GhostState.aiRowIndex
        let usable: String? = {
            guard let s = state.aiSuggestion, !s.isEmpty else { return nil }
            return s
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "sparkles")
                    .foregroundStyle(SolaroColor.accent)
                    .font(.system(size: 11))
                if state.aiLoading {
                    ProgressView().controlSize(.mini)
                    Text("aro ask is thinking…")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                } else {
                    Text("aro ask  ·  ⏎ accept")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                Spacer(minLength: 0)
                if let suggestion = usable {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(suggestion, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(SolaroColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy the AI suggestion")
                }
            }
            if let suggestion = usable {
                SelectableMonoText(text: suggestion)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if state.aiSuggestion != nil, !state.aiLoading {
                Text("(aro ask returned nothing)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
        }
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, SolaroSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Highlight when the user has navigated to the AI row.
        // Clicking anywhere on the section accepts it, mirroring
        // the LSP-row click-to-accept behaviour.
        .background(selected ? SolaroColor.selection : SolaroColor.backdrop)
        .contentShape(Rectangle())
        .onTapGesture {
            if let suggestion = usable {
                onAcceptAI(suggestion)
            }
        }
    }

    // MARK: - Items list

    private var itemsList: some View {
        let visible = state.visibleItems
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        Text(state.typedPrefix.isEmpty
                             ? "(no suggestions)"
                             : "(nothing matches \"\(state.typedPrefix)\")")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .padding(SolaroSpace.s)
                    } else {
                        ForEach(Array(visible.enumerated()), id: \.offset) { idx, item in
                            row(idx: idx, item: item)
                                .id(idx)
                        }
                    }
                }
            }
            .onChange(of: state.selectedIndex) { _, new in
                guard new >= 0 else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private func row(idx: Int, item: AROLSPClient.CompletionItem) -> some View {
        let selected = idx == state.selectedIndex
        return Button {
            onAccept(item)
        } label: {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: kindIcon(item.kind))
                    .foregroundStyle(kindColor(item.kind))
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(item.label)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(1)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SolaroSpace.s)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? SolaroColor.selection : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        let visible = state.visibleItems
        let filtered = !state.typedPrefix.isEmpty
            && visible.count != state.items.count
        return HStack(spacing: SolaroSpace.xs) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(SolaroColor.accent)
                .font(.system(size: 10))
            Text(state.inNavMode
                 ? "↑↓ navigate · ⏎ accept · ⎋ dismiss"
                 : "⇥ to enter · keep typing to refine · ⎋ to dismiss")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer()
            Text(filtered
                 ? "\(visible.count)/\(state.items.count)"
                 : "\(state.items.count)")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, 4)
        .background(SolaroColor.backdrop)
    }

    // MARK: - Styling

    private func kindIcon(_ kind: AROLSPClient.CompletionItem.Kind) -> String {
        switch kind {
        case .keyword:       return "key.fill"
        case .variable:      return "diamond.fill"
        case .function, .method: return "function"
        case .property, .field: return "circle.grid.cross.fill"
        case .snippet:       return "scissors"
        case .module:        return "shippingbox"
        case .constant, .value: return "number"
        default:             return "circle.fill"
        }
    }

    private func kindColor(_ kind: AROLSPClient.CompletionItem.Kind) -> Color {
        switch kind {
        case .keyword:       return SolaroColor.accent
        case .variable:      return SolaroColor.roleOwn
        case .function, .method: return SolaroColor.roleRequest
        case .property, .field: return SolaroColor.roleResponse
        case .snippet:       return SolaroColor.stateWarn
        default:             return SolaroColor.textSecondary
        }
    }
}
