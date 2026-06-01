// ============================================================
// CenterPane.swift
// SOLARO — center pane: text editor / canvas / split / map
// ============================================================
//
// Phase 1: Text. Phase 2: Canvas, Split. Phase 3: Map (note 8519).

import Foundation
import SwiftCrossUI
import AROParser

struct CenterPane: View {
    let file: SourceFileState?
    let paneMode: PaneMode
    /// Phase 3 — every parsed program in the project, used to
    /// build the Project Map.
    let projectPrograms: [AROParser.Program]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if paneMode == .map {
                projectMapView()
            } else if let file {
                Text("\(file.url.lastPathComponent) · \(paneMode.label)")
                    .foregroundColor(.gray)
                    .font(.system(.subheadline))
                switch paneMode {
                case .text:
                    textView(for: file)
                case .canvas:
                    canvasView(for: file)
                case .split:
                    splitView(for: file)
                case .map:
                    // Handled above — split out to avoid the
                    // missing-file case below.
                    EmptyView()
                }
            } else {
                Text("No file open.").foregroundColor(.gray)
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func projectMapView() -> some View {
        let map = ProjectMap.build(from: projectPrograms)
        ProjectMapView(map: map, onSelect: { _ in /* selection in Phase 3 follow-up */ })
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
    private func canvasView(for file: SourceFileState) -> some View {
        CanvasView(graph: graph(for: file))
    }

    @ViewBuilder
    private func splitView(for file: SourceFileState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CanvasView(graph: graph(for: file))
            textView(for: file)
        }
    }

    /// Build + position the canvas graph for the file's first
    /// feature set. Phase 2 scope: one feature set at a time
    /// (the inspector handles multi-feature-set navigation).
    private func graph(for file: SourceFileState) -> CanvasGraph {
        guard
            let program = file.program,
            let firstFS = program.featureSets.first
        else {
            return CanvasGraph(nodes: [], edges: [])
        }
        let built = CanvasGraph.build(featureSet: firstFS, fileKey: file.url.path)
        let withSaved = built.withPositions(from: file.layout)
        return ForceDirectedLayout.place(withSaved)
    }
}
