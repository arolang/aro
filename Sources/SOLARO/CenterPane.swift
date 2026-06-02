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
import Yams

struct CenterPaneView: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        // Touch the OpenAPI document's root so SwiftUI subscribes
        // to its @Observable mutations — this is what makes
        // canvas-driven edits (add route / add schema / etc.) flow
        // through to the text editor view without a manual refresh.
        _ = controller.openAPIDocument?.root.count
        return Group {
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
            if isDiffFile(url) {
                DiffRendererView(source: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editorWithGutters(for: url)
            }
        }
    }

    /// Composite view: optional folded-source pane, the main
    /// editor, and the minimap column on the right. Controlled
    /// by two @AppStorage toggles surfaced in the editor header.
    @ViewBuilder
    private func editorWithGutters(for url: URL) -> some View {
        let folded = UserDefaults.standard.bool(forKey: SolaroPrefs.editorFolded.rawValue)
        let minimap = UserDefaults.standard.bool(forKey: SolaroPrefs.editorMinimap.rawValue)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        HStack(spacing: 0) {
            if folded, let program = controller.programs[url] {
                FoldedSourceView(
                    source: text,
                    program: program,
                    onJumpToLine: { line in
                        UserDefaults.standard.set(false, forKey: SolaroPrefs.editorFolded.rawValue)
                        controller.currentLine = line
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AROCodeEditor(
                    text: editableBinding(for: url),
                    currentLine: currentLineBinding,
                    breakpoints: breakpointsBinding,
                    pausedLine: controller.pausedLine,
                    pauseSymbols: controller.pauseSymbols,
                    language: editorLanguage(for: url),
                    onSave: { saveAndReparse(text: $0, url: url) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if minimap && !folded {
                MinimapView(
                    text: text,
                    currentLine: controller.currentLine,
                    onJumpToLine: { line in controller.currentLine = line }
                )
            }
        }
    }

    /// Diff / patch files render through DiffRendererView instead
    /// of the regular code editor — they're read-only and benefit
    /// from a structured viewer that tints adds / removes.
    private func isDiffFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".diff") || name.hasSuffix(".patch")
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

    /// Pick the syntax highlighter mode for the editor based on
    /// the file extension. ARO sources get the Lexer-driven
    /// coloring; openapi.yaml gets the lightweight YAML pass;
    /// everything else stays uncoloured.
    private func editorLanguage(for url: URL) -> AROCodeEditor.Language {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".aro") { return .aro }
        if name.hasSuffix(".yaml") || name.hasSuffix(".yml") { return .yaml }
        return .plain
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

    /// Lightweight whitespace cleanup applied on save when the
    /// "Format on save" preference is enabled. Strips trailing
    /// whitespace from every line and ensures exactly one trailing
    /// newline. Full AST round-trip pretty-printing is a follow-up.
    private func formatIfEnabled(_ text: String, for url: URL) -> String {
        let enabled = UserDefaults.standard.bool(forKey: SolaroPrefs.formatOnSave.rawValue)
        guard enabled else { return text }
        let suffix = url.lastPathComponent.lowercased()
        if !(suffix.hasSuffix(".aro")
             || suffix.hasSuffix(".yaml")
             || suffix.hasSuffix(".yml")
             || suffix.hasSuffix(".store"))
        {
            return text
        }
        let trimmedLines = text
            .components(separatedBy: "\n")
            .map { line -> String in
                if let lastNonSpace = line.lastIndex(where: { !$0.isWhitespace || $0 == "\t" })
                    .map({ line.index(after: $0) }) ?? (line.isEmpty ? nil : line.startIndex)
                {
                    return String(line[..<lastNonSpace])
                }
                return ""
            }
        var joined = trimmedLines.joined(separator: "\n")
        while joined.hasSuffix("\n\n") { joined.removeLast() }
        if !joined.hasSuffix("\n") { joined += "\n" }
        return joined
    }

    private func editableBinding(for url: URL) -> Binding<String> {
        // OpenAPI files: route text through the @Observable
        // OpenAPIDocument so the canvas (which mutates document.root
        // directly when the user adds a route etc.) and the text
        // editor stay in lock-step both directions. The Inspector's
        // Save button is still what persists to disk.
        if let document = controller.openAPIDocument, document.url == url {
            return Binding(
                get: {
                    (try? Yams.dump(object: document.root, sortKeys: false)) ?? ""
                },
                set: { newValue in
                    if let parsed = try? Yams.load(yaml: newValue) as? [String: Any] {
                        document.root = parsed
                        document.markDirty()
                    }
                }
            )
        }
        return Binding(
            get: { (try? String(contentsOf: url, encoding: .utf8)) ?? "" },
            set: { newValue in
                let formatted = formatIfEnabled(newValue, for: url)
                try? formatted.write(to: url, atomically: true, encoding: .utf8)
                reparse(url: url)
            }
        )
    }

    private func saveAndReparse(text: String, url: URL) {
        let formatted = formatIfEnabled(text, for: url)
        try? formatted.write(to: url, atomically: true, encoding: .utf8)
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
        // Git status may have changed when the file's bytes changed
        // — refresh the cached status so the sidebar + branch chip
        // catch the update.
        controller.gitMonitor.refresh(for: controller.project)
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasMode: some View {
        if let url = controller.currentFile, isOpenAPIFile(url) {
            openAPICanvas(for: url)
        } else {
            CanvasView(
                graph: canvasGraph,
                persistPosition: persistNodePosition(_:to:),
                currentLine: currentLineBinding,
                pausedLine: controller.pausedLine,
                pauseSymbols: controller.pauseSymbols,
                breakpointLines: breakpointsBinding.wrappedValue,
                onActionDrop: { template, point in
                    insertDroppedAction(template: template, at: point)
                },
                onNodeContextAction: { action, node in
                    handleNodeContextAction(action, node: node)
                }
            )
        }
    }

    @ViewBuilder
    private func openAPICanvas(for url: URL) -> some View {
        let document = controller.openAPIDocument
        // Snapshot the dictionary so changes in `document.root`
        // (Yams.dump's input) bypass the disk → SwiftUI re-render
        // is driven by the @Observable's didSet.
        let yaml = document.flatMap { d in
            try? Yams.dump(object: d.root, sortKeys: false)
        } ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let graph = OpenAPIGraphBuilder.build(yaml: yaml)
        let warnings: [OpenAPILintWarning] = {
            guard let document else { return [] }
            return OpenAPILinter.lint(graph: graph, document: document)
        }()
        OpenAPIGraphView(
            yaml: yaml,
            warnings: warnings,
            onSelect: { node in
                controller.openAPISelectedNodeID = node?.id
            },
            onAddRoute: document.map { d in
                {
                    let added = d.addRoute()
                    controller.openAPISelectedNodeID =
                        "route:\(added.method) \(added.path)"
                }
            },
            onAddSchema: document.map { d in
                {
                    let name = d.addSchema()
                    controller.openAPISelectedNodeID = "schema:\(name)"
                }
            },
            onJumpToCode: { node in
                jumpToYAMLDefinition(of: node, in: url, yaml: yaml)
            }
        )
    }

    /// Double-clicking an OpenAPI node should drop the editor's
    /// caret on the route's `<method>:` line (or the schema's
    /// declaration line). We do a forgiving textual scan rather
    /// than tracking source positions through Yams round-trip,
    /// which is plenty for the casual editor jump.
    private func jumpToYAMLDefinition(
        of node: OpenAPINode,
        in url: URL,
        yaml: String
    ) {
        guard let line = OpenAPISourceMap.line(for: node.id, in: yaml) else {
            return
        }
        // Make sure we're actually editing the YAML, then drop the
        // caret on the target line. paneMode stays as the user set
        // it — split mode shows graph + code side-by-side already;
        // canvas-only mode flips to text so the user actually sees
        // the jump land somewhere.
        if controller.paneMode == .canvas {
            controller.paneMode = .text
        }
        controller.currentLine = line
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

    /// Insert a dropped Actions-tab template into the source file.
    /// Pick the feature set whose laid-out bounding box contains
    /// the drop point (or the first feature set if the drop is
    /// outside every box) and splice the template in just before
    /// the feature set's closing `}`.
    private func insertDroppedAction(template: String, at point: CGPoint) {
        guard
            let url = controller.currentFile,
            let program = controller.programs[url]
        else { return }
        let graph = canvasGraph
        let target = featureSetAtPoint(point, in: graph)
            ?? program.featureSets.first?.name
        guard
            let name = target,
            let fs = program.featureSets.first(where: { $0.name == name }),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        let nsText = text as NSString
        let endOffset = fs.span.end.offset
        // The feature set's span.end points at the byte *after*
        // the closing `}`. Walk back to the `}` itself so we
        // insert above it, not after.
        var insertAt = min(endOffset, nsText.length)
        while insertAt > 0, nsText.character(at: insertAt - 1) != 0x7D /* } */ {
            insertAt -= 1
        }
        if insertAt > 0 { insertAt -= 1 }  // sit just before the `}`

        let indent = inferIndent(in: nsText, around: insertAt)
        var snippet = indent + template
        if !snippet.hasSuffix("\n") { snippet += "\n" }

        let updated = nsText.replacingCharacters(
            in: NSRange(location: insertAt, length: 0),
            with: snippet
        )
        try? updated.write(to: url, atomically: true, encoding: .utf8)
        reparse(url: url)
    }

    /// Find the feature set whose laid-out node bounding box
    /// contains `point` in canvas coordinates. Returns nil when
    /// the drop is on empty space.
    private func featureSetAtPoint(_ point: CGPoint, in graph: CanvasGraph) -> String? {
        let nodeW: CGFloat = 240
        let nodeH: CGFloat = 64
        var bounds: [String: CGRect] = [:]
        for node in graph.nodes {
            let rect = CGRect(x: node.x, y: node.y, width: nodeW, height: nodeH)
            let inset = rect.insetBy(dx: -16, dy: -32)  // include FS container chrome
            if let existing = bounds[node.featureSetName] {
                bounds[node.featureSetName] = existing.union(inset)
            } else {
                bounds[node.featureSetName] = inset
            }
        }
        return bounds.first(where: { $0.value.contains(point) })?.key
    }

    /// Sniff a reasonable indentation string by walking back to
    /// the previous newline and copying any leading whitespace.
    /// Fallback: four spaces.
    private func inferIndent(in text: NSString, around offset: Int) -> String {
        var i = offset - 1
        while i >= 0, text.character(at: i) != 0x0A /* \n */ {
            i -= 1
        }
        var start = i + 1
        var end = start
        while end < text.length {
            let c = text.character(at: end)
            if c == 0x20 /* space */ || c == 0x09 /* tab */ {
                end += 1
            } else {
                break
            }
        }
        if end > start {
            return text.substring(with: NSRange(location: start, length: end - start))
        }
        return "    "
    }

    /// Right-click context-menu dispatcher on a canvas node card.
    /// Reveal jumps the caret to the statement's line; duplicate
    /// copies the underlying source text just below the statement;
    /// delete excises the statement's source range and reparses.
    private func handleNodeContextAction(
        _ action: CanvasNodeContextAction,
        node: CanvasNode
    ) {
        switch action {
        case .revealInEditor:
            controller.currentLine = node.lineHint
            controller.setPaneMode(.text)
        case .duplicate:
            mutateStatement(node: node, mode: .duplicate)
        case .delete:
            mutateStatement(node: node, mode: .delete)
        case .extractAsAction:
            controller.requestExtractAction(node: node)
        }
    }

    private enum StatementMutation { case duplicate, delete }

    /// Splice a statement out of the source file (delete) or
    /// re-emit it just below (duplicate) by finding the line
    /// covering `node.lineHint` and operating on the matching
    /// AST statement's source span.
    private func mutateStatement(node: CanvasNode, mode: StatementMutation) {
        guard
            let url = controller.currentFile,
            let program = controller.programs[url],
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        // Find the statement whose start.line == node.lineHint.
        var hit: (start: Int, end: Int)? = nil
        for fs in program.featureSets {
            for statement in fs.statements {
                if statement.span.start.line == node.lineHint {
                    hit = (statement.span.start.offset,
                           statement.span.end.offset)
                    break
                }
            }
            if hit != nil { break }
        }
        guard let (startOff, endOff) = hit else { return }
        let nsText = text as NSString
        guard startOff >= 0, endOff <= nsText.length, endOff > startOff
        else { return }

        // Walk back to the start of the line so we delete the
        // indentation too, and forward to (and including) the
        // trailing newline so the gap closes cleanly.
        var lineStart = startOff
        while lineStart > 0, nsText.character(at: lineStart - 1) != 0x0A {
            lineStart -= 1
        }
        var lineEnd = endOff
        while lineEnd < nsText.length, nsText.character(at: lineEnd) != 0x0A {
            lineEnd += 1
        }
        if lineEnd < nsText.length { lineEnd += 1 }  // consume newline

        let removalRange = NSRange(location: lineStart, length: lineEnd - lineStart)
        let statementText = nsText.substring(with: removalRange)

        var updated: String
        switch mode {
        case .delete:
            updated = nsText.replacingCharacters(in: removalRange, with: "")
        case .duplicate:
            updated = nsText.replacingCharacters(
                in: NSRange(location: lineEnd, length: 0),
                with: statementText
            )
        }
        try? updated.write(to: url, atomically: true, encoding: .utf8)
        reparse(url: url)
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
            splitLeftPane
                .frame(minWidth: 240)
            if let url = controller.currentFile {
                AROCodeEditor(
                    text: editableBinding(for: url),
                    currentLine: currentLineBinding,
                    breakpoints: breakpointsBinding,
                    pausedLine: controller.pausedLine,
                    pauseSymbols: controller.pauseSymbols,
                    language: editorLanguage(for: url),
                    onSave: { saveAndReparse(text: $0, url: url) }
                )
                .frame(minWidth: 240)
            }
        }
    }

    /// Picks the canvas-side view for split mode based on the
    /// current file: OpenAPI graph for openapi.yaml, ARO action
    /// graph otherwise. Previously this hardcoded `CanvasView`,
    /// which left the OpenAPI graph reachable only in canvas-only
    /// mode and broke split editing on openapi.yaml.
    @ViewBuilder
    private var splitLeftPane: some View {
        if let url = controller.currentFile, isOpenAPIFile(url) {
            openAPICanvas(for: url)
        } else {
            CanvasView(
                graph: canvasGraph,
                persistPosition: persistNodePosition(_:to:),
                currentLine: currentLineBinding,
                pausedLine: controller.pausedLine,
                pauseSymbols: controller.pauseSymbols,
                breakpointLines: breakpointsBinding.wrappedValue,
                onActionDrop: { template, point in
                    insertDroppedAction(template: template, at: point)
                },
                onNodeContextAction: { action, node in
                    handleNodeContextAction(action, node: node)
                }
            )
        }
    }

    private func isOpenAPIFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == "openapi.yaml" || name == "openapi.yml"
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
