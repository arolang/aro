// ============================================================
// EditorFind.swift
// SOLARO — ⌘F find bar that overlays the source editor
// ============================================================
//
// Pressing ⌘F with focus inside the text editor opens a small
// find bar in the top-right of the editor pane:
//
//   ┌──────────────────────────────────────────────────────┐
//   │ 🔍 query…                3 of 12   ▲ ▼  ×           │
//   └──────────────────────────────────────────────────────┘
//
// Typing in the field rebuilds the match list across the
// current file's text. Return jumps to the next match; Shift+
// Return jumps to the previous match; Esc closes the bar.
// Clicking ▲/▼ does the same. The bar updates the controller's
// `editorFindSelection` so AROCodeEditor selects + scrolls to
// the chosen match.
//
// Scope: case-insensitive substring across the file currently
// open in the editor. Regex / case sensitivity toggles are
// follow-ups — this lands the surface and the shortcut.

import SwiftUI

@MainActor
struct EditorFindBar: View {
    @Bindable var controller: WorkspaceController
    /// The text of the currently-open source file. Closure so
    /// the bar always reads the freshest text without holding
    /// onto a stale snapshot across edits.
    let fileText: () -> String

    @State private var matches: [NSRange] = []
    @State private var currentIndex: Int = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(SolaroColor.textSecondary)
            TextField("Find in file", text: $controller.editorFindQuery)
                .textFieldStyle(.plain)
                .font(SolaroFont.body)
                .frame(minWidth: 180, maxWidth: 260)
                .focused($focused)
                .onSubmit {
                    advance(by: NSEvent.modifierFlags.contains(.shift) ? -1 : 1)
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
            Text(matchCountLabel)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
            Button { advance(by: -1) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(matches.isEmpty)
            .help("Previous match (⇧⏎)")
            .keyboardShortcut("g", modifiers: [.command, .shift])
            Button { advance(by: 1) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(matches.isEmpty)
            .help("Next match (⏎)")
            .keyboardShortcut("g", modifiers: [.command])
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(SolaroColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(SolaroColor.textTertiary.opacity(0.3))
        )
        .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 3)
        .onAppear {
            focused = true
            recompute(jumpTo: 0)
        }
        .onChange(of: controller.editorFindQuery) { _, _ in
            recompute(jumpTo: 0)
        }
    }

    private var matchCountLabel: String {
        if controller.editorFindQuery.isEmpty { return "" }
        if matches.isEmpty { return "No matches" }
        return "\(currentIndex + 1) of \(matches.count)"
    }

    private func recompute(jumpTo idx: Int) {
        let query = controller.editorFindQuery
        guard !query.isEmpty else {
            matches = []
            currentIndex = 0
            return
        }
        let text = fileText()
        matches = findAllRanges(of: query, in: text)
        guard !matches.isEmpty else {
            currentIndex = 0
            return
        }
        currentIndex = min(max(idx, 0), matches.count - 1)
        controller.requestEditorFindSelection(matches[currentIndex])
    }

    private func advance(by delta: Int) {
        guard !matches.isEmpty else { return }
        // Wrap around in both directions — feels nicer than
        // bouncing off the ends when there's only a handful of
        // matches.
        let count = matches.count
        currentIndex = ((currentIndex + delta) % count + count) % count
        controller.requestEditorFindSelection(matches[currentIndex])
    }

    private func close() {
        controller.editorFindActive = false
        controller.editorFindQuery = ""
        matches = []
        currentIndex = 0
    }

    /// Case-insensitive substring scan returning every match
    /// range. Operates on NSString so the indices line up with
    /// the UTF-16 offsets STTextView's `setSelectedRange` wants.
    private func findAllRanges(of needle: String,
                                in haystack: String) -> [NSRange] {
        let ns = haystack as NSString
        var out: [NSRange] = []
        var cursor = 0
        while cursor < ns.length {
            let search = NSRange(location: cursor, length: ns.length - cursor)
            let r = ns.range(of: needle,
                             options: .caseInsensitive,
                             range: search)
            if r.location == NSNotFound { break }
            out.append(r)
            cursor = r.location + max(r.length, 1)
        }
        return out
    }
}
