// ============================================================
// CenterPane.swift
// SOLARO — center pane dispatcher (Phase 7 onwards)
// ============================================================
//
// Dispatches the right view for the current pane mode. Phase 7
// ships the Text mode (CodeEditor); Phases 8/10 add Canvas, Split,
// and Map. The shared empty-state UI lives here so each mode's
// view can stay focused.

import SwiftUI
import AROParser

struct CenterPaneView: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        Group {
            if controller.currentFile == nil, controller.paneMode != .map {
                emptyPane("Select a file from the sidebar.")
            } else {
                switch controller.paneMode {
                case .text:   textMode
                case .canvas: canvasMode
                case .split:  splitMode
                case .map:    mapMode
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SolaroColor.backdrop)
    }

    // MARK: - Text

    @ViewBuilder
    private var textMode: some View {
        if let url = controller.currentFile {
            AROCodeEditor(
                text: editableBinding(for: url),
                currentLine: currentLineBinding,
                breakpoints: breakpointsBinding,
                pausedLine: controller.pausedLine,
                pauseSymbols: controller.pauseSymbols,
                onSave: { saveAndReparse(text: $0, url: url) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Binding mediating the editor cursor's line ↔ canvas node
    /// highlight. Both views read + write to the same controller
    /// property, which avoids feedback loops as long as we only
    /// emit when the value actually changes.
    private var currentLineBinding: Binding<Int?> {
        Binding(
            get: { controller.currentLine },
            set: { newValue in
                if controller.currentLine != newValue {
                    controller.currentLine = newValue
                }
            }
        )
    }

    /// Binding to the current file's breakpoints (1-indexed lines).
    /// Reads from the per-file LayoutSidecar; mutations write back
    /// to disk so the set survives a relaunch.
    private var breakpointsBinding: Binding<Set<Int>> {
        Binding(
            get: {
                guard let url = controller.currentFile else { return [] }
                return LayoutSidecar.load(for: url).breakpoints
            },
            set: { newValue in
                guard let url = controller.currentFile else { return }
                var sidecar = LayoutSidecar.load(for: url)
                sidecar.breakpoints = newValue
                try? sidecar.save(for: url)
            }
        )
    }

    private func editableBinding(for url: URL) -> Binding<String> {
        Binding(
            get: { (try? String(contentsOf: url, encoding: .utf8)) ?? "" },
            set: { newValue in
                try? newValue.write(to: url, atomically: true, encoding: .utf8)
                reparse(url: url)
            }
        )
    }

    private func saveAndReparse(text: String, url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
        reparse(url: url)
    }

    private func reparse(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            controller.parseErrors[url] = "Could not read file."
            controller.programs.removeValue(forKey: url)
            return
        }
        do {
            controller.programs[url] = try Parser.parse(text)
            controller.parseErrors.removeValue(forKey: url)
        } catch {
            controller.parseErrors[url] = "\(error)"
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasMode: some View {
        if let url = controller.currentFile,
           url.lastPathComponent.lowercased() == "openapi.yaml"
            || url.lastPathComponent.lowercased() == "openapi.yml"
        {
            openAPICanvas(for: url)
        } else {
            CanvasView(
                graph: canvasGraph,
                persistPosition: persistNodePosition(_:to:),
                currentLine: currentLineBinding,
                pausedLine: controller.pausedLine,
                pauseSymbols: controller.pauseSymbols,
                breakpointLines: breakpointsBinding.wrappedValue
            )
        }
    }

    @ViewBuilder
    private func openAPICanvas(for url: URL) -> some View {
        let yaml = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        OpenAPIGraphView(yaml: yaml) { node in
            // Selection drives the inspector's editable form
            // (forthcoming follow-up); for now we mirror the
            // selected route's operationId line into the editor
            // caret so users get a familiar focus signal.
            if let node, case .route(_, _, _, let opId) = node.kind {
                controller.openAPISelectedNodeID = node.id
                if let _ = opId {
                    // No-op for now; future hook into editor caret.
                }
            } else {
                controller.openAPISelectedNodeID = node?.id
            }
        }
    }

    private var canvasGraph: CanvasGraph {
        guard
            let url = controller.currentFile,
            let program = controller.programs[url]
        else {
            return CanvasGraph(nodes: [], edges: [])
        }
        let sidecar = LayoutSidecar.load(for: url)
        // Build one graph spanning every feature set in the file —
        // statements are tagged with their parent feature-set name
        // so the canvas can group them in colored containers.
        let built = CanvasGraph.build(program: program, fileKey: url.path)
            .withPositions(from: sidecar)
        return StackLayout.place(built)
    }

    /// Drag-end callback: persist this node's new `(x, y)` to the
    /// per-file `.aro.layout.json` sidecar so it survives a reload.
    private func persistNodePosition(_ id: CanvasNode.ID, to point: CGPoint) {
        guard let url = controller.currentFile else { return }
        var sidecar = LayoutSidecar.load(for: url)
        sidecar.nodes[id] = LayoutSidecar.NodePosition(
            x: Double(point.x), y: Double(point.y)
        )
        try? sidecar.save(for: url)
    }

    // MARK: - Split

    @ViewBuilder
    private var splitMode: some View {
        HSplitView {
            CanvasView(
                graph: canvasGraph,
                persistPosition: persistNodePosition(_:to:),
                currentLine: currentLineBinding,
                pausedLine: controller.pausedLine,
                pauseSymbols: controller.pauseSymbols,
                breakpointLines: breakpointsBinding.wrappedValue
            )
            .frame(minWidth: 240)
            if let url = controller.currentFile {
                AROCodeEditor(
                    text: editableBinding(for: url),
                    currentLine: currentLineBinding,
                    breakpoints: breakpointsBinding,
                    pausedLine: controller.pausedLine,
                    pauseSymbols: controller.pauseSymbols,
                    onSave: { saveAndReparse(text: $0, url: url) }
                )
                .frame(minWidth: 240)
            }
        }
    }

    @ViewBuilder
    private var mapMode: some View {
        let map = ProjectMap.build(from: controller.allPrograms)
        ProjectMapView(map: map) { node in
            // Phase 10: locate which source file declares this
            // feature set and switch to it. The text editor's
            // scroll-to-feature-set position lands as a follow-up.
            if let url = sourceURL(for: node.featureSetName) {
                controller.openFile(url)
                controller.setPaneMode(.text)
            }
        }
    }

    private func sourceURL(for featureSetName: String) -> URL? {
        guard let model = controller.model else { return nil }
        for url in model.sourceFiles {
            if let program = controller.programs[url],
               program.featureSets.contains(where: { $0.name == featureSetName }) {
                return url
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func emptyPane(_ text: String) -> some View {
        VStack(spacing: SolaroSpace.s) {
            Image(systemName: controller.paneMode.symbol)
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(SolaroColor.textTertiary)
            Text(controller.paneMode.label)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(SolaroColor.textSecondary)
            Text(text)
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
