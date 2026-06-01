// ============================================================
// CenterPane.swift
// SOLARO — center pane: text editor / canvas / split / map
// ============================================================
//
// Phase 1 only renders the Text mode; Canvas / Split / Map land
// in Phase 2 (canvas) and Phase 2+ (Map view from note 8519).

import Foundation
import SwiftCrossUI

struct CenterPane: View {
    let file: SourceFileState?
    let paneMode: PaneMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let file {
                Text("\(file.url.lastPathComponent) · \(paneMode.label)")
                    .foregroundColor(.gray)
                    .font(.system(.subheadline))
                switch paneMode {
                case .text:
                    textView(for: file)
                case .canvas:
                    canvasPlaceholder
                case .split:
                    splitPlaceholder
                case .map:
                    mapPlaceholder
                }
            } else {
                Text("No file open.").foregroundColor(.gray)
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func textView(for file: SourceFileState) -> some View {
        // SwiftCrossUI's TextEditor is the multiline text widget.
        // The actual native widget wired in by each backend
        // (AppKit's NSTextView, GTK's GtkTextView, etc.) handles
        // multi-line input, cursor placement, and selection.
        // Phase 1 binds to a snapshot of the file's text via a
        // simple wrapper; Phase 2 will wire the AST patches.
        TextEditor(text: editableBinding(for: file))
    }

    /// Phase 1 doesn't yet plumb edits back to the AST. The binding
    /// reflects the current buffer; mutations re-parse on the next
    /// `reparse()` call from the toolbar's Save action.
    private func editableBinding(for file: SourceFileState) -> Binding<String> {
        Binding(get: { file.text }, set: { newValue in
            file.text = newValue
            file.reparse()
        })
    }

    @ViewBuilder
    private var canvasPlaceholder: some View {
        Text("Canvas mode lands in Phase 2 (#228).")
            .foregroundColor(.gray)
    }

    @ViewBuilder
    private var splitPlaceholder: some View {
        Text("Split mode shows Canvas + Text together — Phase 2.")
            .foregroundColor(.gray)
    }

    @ViewBuilder
    private var mapPlaceholder: some View {
        Text("Project Map mode (note 8519) lands in Phase 3.")
            .foregroundColor(.gray)
    }
}
