// ============================================================
// ReplNotebookView.swift
// SOLARO — the .repl notebook editor
// ============================================================
//
// Jupyter-shaped editing for `.repl` files: markdown cells render
// as prose, code cells run against a live `aro repl --json`
// session (ARO-0091 — the exact protocol the Jupyter kernel
// speaks), outputs land under the cell as they stream in.
//
// Layout: a slim notebook toolbar (run all / run above /
// interrupt / add cells / kernel status), then a centered cell
// column. Each cell row is [gutter | card]: the gutter carries the
// run affordance and the `[n]` execution badge, the card carries
// the editor (or rendered markdown) and the outputs. Cell chrome
// (move / convert / insert / delete) appears on hover, top-right,
// so the resting state stays quiet.
//
// Chords match Jupyter. While editing: ⇧⏎ run & select below, ⌥⏎
// run & insert below, ⌘⏎ run in place, Esc drops to command mode.
// In command mode (a cell selected, no editor focused): ↑/↓ move
// between cells, ⏎ starts editing, A/B insert above/below, DD
// deletes, M/Y convert, ⇧M merges with the cell below, ⌘D
// duplicates, ⌘X/⌘C/⌘V cut/copy/paste whole cells. All of them are
// remappable in Settings → Keybindings; the map lives in
// ReplNotebookCommands.swift (GitLab #538).

import SwiftUI
import AppKit

// MARK: - Entry

struct ReplNotebookView: View {
    @Bindable var notebook: ReplNotebookController

    @AppStorage(SolaroPrefs.editorFontSize.rawValue)
    private var editorFontSize: Double = 13

    /// Workspace-scoped UndoManager — the notebook's structural
    /// operations register on it so ⌘Z brings a deleted cell back
    /// (GitLab #537).
    @Environment(\.solaroUndoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            ReplNotebookToolbar(notebook: notebook)
            Rectangle()
                .fill(SolaroColor.divider)
                .frame(height: 1)
            if let error = notebook.loadError {
                loadErrorView(error)
            } else {
                kernelDeathBanner
                cellColumn
            }
        }
        .background(SolaroColor.backdrop)
        .onAppear { notebook.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in
            notebook.undoManager = manager
        }
        .onDisappear { notebook.saveNow() }
    }

    private func loadErrorView(_ message: String) -> some View {
        VStack(spacing: SolaroSpace.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(SolaroColor.stateWarn)
            Text("Couldn't open this notebook")
                .font(SolaroFont.bodyBold)
            Text(message)
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The kernel died outside a deliberate shutdown — say so once,
    /// with the restart right there.
    @ViewBuilder
    private var kernelDeathBanner: some View {
        if case .dead(let reason) = notebook.kernel.state {
            HStack(spacing: SolaroSpace.s) {
                Image(systemName: "bolt.slash.fill")
                    .foregroundStyle(SolaroColor.stateError)
                Text(reason)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Restart Kernel") { notebook.restartKernel() }
                    .buttonStyle(.plain)
                    .font(SolaroFont.caption.weight(.semibold))
                    .foregroundStyle(SolaroColor.accent)
            }
            .padding(.horizontal, SolaroSpace.m)
            .padding(.vertical, SolaroSpace.s)
            .background(SolaroColor.stateError.opacity(0.10))
            .overlay(alignment: .bottom) {
                Rectangle().fill(SolaroColor.divider).frame(height: 1)
            }
        }
    }

    private var cellColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(notebook.cells) { cell in
                        ReplCellRow(
                            notebook: notebook,
                            cellID: cell.id,
                            fontSize: CGFloat(editorFontSize)
                        )
                        .id(cell.id)
                    }
                    trailingAddButtons
                        .padding(.top, SolaroSpace.s)
                        .padding(.bottom, 120)
                }
                // Fill the editor pane rather than sitting in a fixed
                // 880pt column. A notebook's content is mostly code, tables
                // and output — the things that suffer most from being
                // wrapped early — and on a wide window the old cap left
                // roughly a third of the pane empty on either side while
                // the code inside scrolled or wrapped. The column now
                // tracks the pane, so resizing the window or collapsing a
                // sidebar gives the cells the space back.
                .frame(maxWidth: .infinity)
                .padding(.horizontal, SolaroSpace.l)
                .padding(.top, SolaroSpace.l)
            }
            // Scroll only when the notebook moved the selection for
            // the user (keyboard navigation, run-and-advance, a new
            // cell), never when they clicked a cell themselves — a
            // click means they can already see it, and scrolling then
            // threw the reader back to the top of the notebook.
            .onChange(of: notebook.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: nil)
                notebook.scrollTarget = nil
            }
        }
        // Command mode's keyboard. It only takes first responder
        // while `commandMode` is on, which is exactly when no cell
        // editor wants it.
        .background(
            NotebookCommandKeys(notebook: notebook,
                                active: notebook.commandMode)
                .frame(width: 1, height: 1),
            alignment: .topLeading)
    }

    /// The quiet "grow the notebook" affordance under the last cell.
    private var trailingAddButtons: some View {
        HStack(spacing: SolaroSpace.s) {
            addButton(label: "Code", symbol: "chevron.left.forwardslash.chevron.right") {
                notebook.addCell(kind: .code, after: notebook.cells.last?.id)
            }
            addButton(label: "Markdown", symbol: "text.alignleft") {
                notebook.addCell(kind: .markdown, after: notebook.cells.last?.id)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func addButton(label: String, symbol: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(SolaroFont.caption)
            }
            .foregroundStyle(SolaroColor.textSecondary)
            .padding(.horizontal, SolaroSpace.m)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(SolaroColor.surfaceRaised.opacity(0.7)))
            .overlay(
                Capsule().stroke(SolaroColor.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toolbar

private struct ReplNotebookToolbar: View {
    @Bindable var notebook: ReplNotebookController
    @State private var showKernelPopover = false

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            toolbarButton("play.fill", "Run All",
                          help: "Run every code cell, top to bottom") {
                notebook.runAll()
            }
            toolbarButton("play.square.stack", "Run Above",
                          help: "Run all code cells above the selected cell",
                          disabled: notebook.selectedCellID == nil) {
                if let id = notebook.selectedCellID { notebook.runAllAbove(id) }
            }
            toolbarButton("stop.fill", "Stop",
                          help: "Interrupt — kills the session; its variables and definitions are lost",
                          tint: SolaroColor.stateError,
                          disabled: !notebook.isExecuting) {
                notebook.interrupt()
            }

            toolbarDivider

            toolbarButton("plus", "Code",
                          help: "Insert a code cell below the selection") {
                notebook.addCell(kind: .code, after: notebook.selectedCellID)
            }
            toolbarButton("plus", "Markdown",
                          help: "Insert a markdown cell below the selection") {
                notebook.addCell(kind: .markdown, after: notebook.selectedCellID)
            }

            Spacer(minLength: 0)

            kernelChip
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, 6)
        .background(SolaroColor.surface)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(SolaroColor.divider)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    private func toolbarButton(_ symbol: String, _ label: String,
                               help: String,
                               tint: Color = SolaroColor.textPrimary,
                               disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(SolaroFont.caption)
            }
            .foregroundStyle(disabled ? SolaroColor.textTertiary : tint)
            .padding(.horizontal, SolaroSpace.s)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: SolaroRadius.s)
                    .fill(SolaroColor.surfaceRaised.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    // MARK: Kernel status

    private var kernelState: (color: Color, label: String) {
        switch notebook.kernel.state {
        case .stopped:  return (SolaroColor.textTertiary, "Kernel idle")
        case .starting: return (SolaroColor.stateWarn, "Starting…")
        case .ready:    return (SolaroColor.stateOK, kernelTitle)
        case .busy:     return (SolaroColor.stateWarn, "Running…")
        case .dead:     return (SolaroColor.stateError, "Kernel died")
        }
    }

    private var kernelTitle: String {
        if let version = notebook.kernel.serverVersion {
            return "ARO \(version)"
        }
        return "Ready"
    }

    private var kernelChip: some View {
        Button {
            showKernelPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(kernelState.color)
                    .frame(width: 7, height: 7)
                Text(kernelState.label)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .padding(.horizontal, SolaroSpace.s)
            .padding(.vertical, 4)
            .background(Capsule().fill(SolaroColor.surfaceRaised.opacity(0.6)))
            .overlay(Capsule().stroke(SolaroColor.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Kernel session — variables, feature sets, restart")
        .popover(isPresented: $showKernelPopover, arrowEdge: .bottom) {
            ReplKernelPopover(notebook: notebook)
        }
    }
}

// MARK: - Kernel popover

private struct ReplKernelPopover: View {
    @Bindable var notebook: ReplNotebookController

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            Text("KERNEL SESSION")
                .font(SolaroFont.caption)
                .tracking(1)
                .foregroundStyle(SolaroColor.textTertiary)

            if let info = notebook.kernelInfo {
                sessionSection("Variables", items: info.variables,
                               emptyText: "No variables yet.")
                sessionSection("Feature Sets", items: info.featureSets,
                               emptyText: "No feature sets defined.")
            } else {
                Text(notebook.kernel.state.isRunning
                     ? "Run a cell to populate the session."
                     : "The kernel starts on the first run.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textSecondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                popoverAction("arrow.clockwise", "Restart Kernel") {
                    notebook.restartKernel()
                }
                popoverAction("arrow.clockwise.circle", "Restart & Run All") {
                    notebook.restartAndRunAll()
                }
                popoverAction("eraser", "Clear All Outputs") {
                    notebook.clearAllOutputs()
                }
            }
        }
        .padding(SolaroSpace.l)
        .frame(width: 260)
    }

    @ViewBuilder
    private func sessionSection(_ title: String, items: [String],
                                emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(SolaroFont.caption.weight(.semibold))
                .foregroundStyle(SolaroColor.textSecondary)
            if items.isEmpty {
                Text(emptyText)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            } else {
                // Chips wrap poorly in a fixed popover; a compact
                // mono list reads better for identifier names.
                Text(items.sorted().joined(separator: "  ·  "))
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
    }

    private func popoverAction(_ symbol: String, _ label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: SolaroSpace.s) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(label)
                    .font(SolaroFont.body)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(SolaroColor.textPrimary)
    }
}

// MARK: - Cell row

private struct ReplCellRow: View {
    @Bindable var notebook: ReplNotebookController
    let cellID: String
    let fontSize: CGFloat

    @State private var hovering = false
    @State private var hoveringInsertBar = false

    private var cell: ReplNotebookCell? {
        notebook.cells.first { $0.id == cellID }
    }

    private var isSelected: Bool { notebook.selectedCellID == cellID }
    private var isRunning: Bool { notebook.runningCellID == cellID }
    private var isQueued: Bool { notebook.isQueued(cellID) && !isRunning }

    var body: some View {
        if let cell {
            VStack(spacing: 0) {
                insertBar
                HStack(alignment: .top, spacing: SolaroSpace.s) {
                    gutter(for: cell)
                    card(for: cell)
                }
                .padding(.horizontal, SolaroSpace.l)
            }
            .onHover { hovering = $0 }
            .contextMenu { contextMenu(for: cell) }
        }
    }

    // MARK: Insert bar (between cells)

    /// A slim hover zone above each cell that reveals inline
    /// "+ Code / + Markdown" pills — the modern-notebook insert
    /// affordance. Fixed height so revealing it never reflows the
    /// cells (animated height changes are how the macOS 26
    /// layout-cycle crash gets summoned — see NewFileSheet).
    private var insertBar: some View {
        ZStack {
            Color.clear
            if hoveringInsertBar {
                HStack(spacing: SolaroSpace.s) {
                    insertPill("Code") {
                        notebook.addCell(kind: .code, before: cellID)
                    }
                    insertPill("Markdown") {
                        notebook.addCell(kind: .markdown, before: cellID)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveringInsertBar = inside
            }
        }
    }

    private func insertPill(_ label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(SolaroColor.textSecondary)
            .padding(.horizontal, SolaroSpace.s)
            .padding(.vertical, 2)
            .background(Capsule().fill(SolaroColor.surfaceRaised))
            .overlay(Capsule().stroke(SolaroColor.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Gutter

    private func gutter(for cell: ReplNotebookCell) -> some View {
        VStack(spacing: 4) {
            if cell.kind == .code {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                } else if isQueued {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(SolaroColor.stateWarn)
                        .frame(width: 22, height: 22)
                        .help("Queued")
                } else {
                    Button {
                        notebook.selectedCellID = cellID
                        notebook.runCell(cellID)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(
                                hovering || isSelected
                                    ? SolaroColor.accent
                                    : SolaroColor.textTertiary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 22, height: 22)
                    .help("Run cell (⇧⏎ runs and selects below)")
                }
                Text(executionBadge(for: cell))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(SolaroColor.textTertiary)
            } else {
                // Markdown gutter: a quiet glyph so rows align.
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10))
                    .foregroundStyle(SolaroColor.textTertiary
                        .opacity(hovering || isSelected ? 0.8 : 0.3))
                    .frame(width: 22, height: 22)
            }
        }
        .frame(width: 34)
        .padding(.top, 2)
    }

    private func executionBadge(for cell: ReplNotebookCell) -> String {
        if let count = cell.executionCount { return "[\(count)]" }
        return "[ ]"
    }

    // MARK: Card

    @ViewBuilder
    private func card(for cell: ReplNotebookCell) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch cell.kind {
            case .code:
                codeEditor(for: cell)
                if !cell.outputs.isEmpty || cell.durationMs != nil {
                    ReplCellOutputsView(cell: cell)
                }
            case .markdown:
                if notebook.editingMarkdownIDs.contains(cell.id) {
                    markdownEditor(for: cell)
                } else {
                    renderedMarkdown(for: cell)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(for: cell))
        .overlay(cardBorder)
        .overlay(alignment: .leading) { selectionStripe }
        .overlay(alignment: .topTrailing) {
            if hovering { hoverToolbar(for: cell) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            notebook.selectedCellID = cellID
            // Clicking a rendered markdown cell selects it without
            // opening an editor — that's command mode, and the cell
            // keys should work there.
            notebook.commandMode =
                cell.kind == .markdown
                && !notebook.editingMarkdownIDs.contains(cellID)
        }
    }

    @ViewBuilder
    private func cardBackground(for cell: ReplNotebookCell) -> some View {
        // Code cells sit on a raised surface like every SOLARO
        // card; rendered markdown stays on the backdrop so prose
        // reads as prose, not as a widget.
        if cell.kind == .code || notebook.editingMarkdownIDs.contains(cell.id) {
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .fill(SolaroColor.surfaceRaised.opacity(0.55))
        } else {
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .fill(isSelected
                      ? SolaroColor.surfaceRaised.opacity(0.25)
                      : Color.clear)
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
            .stroke(
                isSelected ? SolaroColor.accent.opacity(0.55) : SolaroColor.divider,
                lineWidth: 1)
    }

    @ViewBuilder
    private var selectionStripe: some View {
        if isSelected {
            UnevenRoundedRectangle(
                topLeadingRadius: SolaroRadius.m,
                bottomLeadingRadius: SolaroRadius.m)
                .fill(SolaroColor.accent)
                .frame(width: 3)
        }
    }

    // MARK: Editors

    private func codeEditor(for cell: ReplNotebookCell) -> some View {
        ReplCellTextView(
            text: sourceBinding(for: cell.id),
            language: .aro,
            fontSize: fontSize,
            // Command mode owns the keyboard while it's on, so the
            // editor must not grab focus back from under it.
            wantsFocus: isSelected && !notebook.commandMode,
            onFocus: {
                notebook.selectedCellID = cellID
                notebook.commandMode = false
            },
            onRunAndAdvance: { notebook.runCellAndAdvance(cellID) },
            onRunAndInsert: { notebook.runCellAndInsertBelow(cellID) },
            onRunInPlace: { notebook.runCell(cellID) },
            // Jupyter's Esc: leave the editor, keep the cell
            // selected, hand the keyboard to command mode.
            onEscape: { notebook.commandMode = true }
        )
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, 2)
        .overlay(alignment: .topLeading) {
            if cell.source.isEmpty {
                Text("ARO statements — ⇧⏎ to run")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(SolaroColor.textTertiary.opacity(0.6))
                    .padding(.leading, SolaroSpace.s + 8)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    private func markdownEditor(for cell: ReplNotebookCell) -> some View {
        ReplCellTextView(
            text: sourceBinding(for: cell.id),
            language: .markdown,
            fontSize: fontSize,
            wantsFocus: isSelected && !notebook.commandMode,
            onFocus: {
                notebook.selectedCellID = cellID
                notebook.commandMode = false
            },
            onRunAndAdvance: { notebook.runCellAndAdvance(cellID) },
            onRunAndInsert: { notebook.runCellAndInsertBelow(cellID) },
            onRunInPlace: { notebook.runCell(cellID) },
            onEscape: {
                notebook.editingMarkdownIDs.remove(cellID)
                notebook.commandMode = true
            }
        )
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, 2)
        .overlay(alignment: .topLeading) {
            if cell.source.isEmpty {
                Text("Markdown — ⇧⏎ to render")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(SolaroColor.textTertiary.opacity(0.6))
                    .padding(.leading, SolaroSpace.s + 8)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    private func renderedMarkdown(for cell: ReplNotebookCell) -> some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            if cell.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Empty markdown cell — double-click to edit")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            } else {
                ForEach(Array(BookMarkdownParser.parse(cell.source).enumerated()),
                        id: \.offset) { _, block in
                    BookMarkdownBlockView(block: block, style: .editor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SolaroSpace.m)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded {
            notebook.selectedCellID = cellID
            notebook.commandMode = false
            notebook.editingMarkdownIDs.insert(cellID)
        })
    }

    private func sourceBinding(for id: String) -> Binding<String> {
        Binding(
            get: { notebook.cells.first { $0.id == id }?.source ?? "" },
            set: { notebook.updateSource($0, for: id) }
        )
    }

    // MARK: Hover toolbar + context menu

    private func hoverToolbar(for cell: ReplNotebookCell) -> some View {
        HStack(spacing: 2) {
            hoverButton("arrow.up", help: "Move cell up") {
                notebook.moveCell(cellID, by: -1)
            }
            hoverButton("arrow.down", help: "Move cell down") {
                notebook.moveCell(cellID, by: 1)
            }
            hoverButton(
                cell.kind == .code ? "text.alignleft" : "chevron.left.forwardslash.chevron.right",
                help: cell.kind == .code
                    ? "Convert to markdown" : "Convert to code") {
                notebook.convertCell(
                    cellID, to: cell.kind == .code ? .markdown : .code)
            }
            hoverButton("trash", help: "Delete cell",
                        tint: SolaroColor.stateError) {
                notebook.deleteCell(cellID)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: SolaroRadius.s, style: .continuous)
                .fill(SolaroColor.surfaceRaised)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.s, style: .continuous)
                .stroke(SolaroColor.divider, lineWidth: 1))
        .padding(6)
        .transition(.opacity)
    }

    private func hoverButton(_ symbol: String, help: String,
                             tint: Color = SolaroColor.textSecondary,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func contextMenu(for cell: ReplNotebookCell) -> some View {
        if cell.kind == .code {
            Button("Run Cell") { notebook.runCell(cellID) }
            Button("Run All Above") { notebook.runAllAbove(cellID) }
            Button("Run Cell and Below") { notebook.runCellAndBelow(cellID) }
            Divider()
        } else if !notebook.editingMarkdownIDs.contains(cellID) {
            Button("Edit Markdown") {
                notebook.editingMarkdownIDs.insert(cellID)
            }
            Divider()
        }
        Button("Insert Code Cell Above") {
            notebook.addCell(kind: .code, before: cellID)
        }
        Button("Insert Code Cell Below") {
            notebook.addCell(kind: .code, after: cellID)
        }
        Button("Insert Markdown Cell Below") {
            notebook.addCell(kind: .markdown, after: cellID)
        }
        Divider()
        Button("Cut Cell") { notebook.cutCell(cellID) }
        Button("Copy Cell") { notebook.copyCell(cellID) }
        Button("Paste Cell Below") { notebook.pasteCells(after: cellID) }
        Button("Duplicate Cell") { notebook.duplicateCell(cellID) }
        if let idx = notebook.cellIndex(of: cellID),
           idx + 1 < notebook.cells.count {
            Button("Merge with Cell Below") { notebook.mergeCellBelow(cellID) }
        }
        Divider()
        Button(cell.kind == .code
               ? "Convert to Markdown" : "Convert to Code") {
            notebook.convertCell(
                cellID, to: cell.kind == .code ? .markdown : .code)
        }
        Button("Delete Cell", role: .destructive) {
            notebook.deleteCell(cellID)
        }
    }
}

// MARK: - Outputs

private struct ReplCellOutputsView: View {
    let cell: ReplNotebookCell

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(SolaroColor.divider)
                .frame(height: 1)
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                ForEach(Array(cell.outputs.enumerated()), id: \.offset) { _, output in
                    // `.equatable()` so an output that hasn't changed
                    // skips its body entirely while a *sibling* cell
                    // streams and invalidates the whole column
                    // (GitLab #540).
                    ReplCellOutputView(output: output).equatable()
                }
                footer
            }
            .padding(SolaroSpace.m)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let duration = cell.durationMs {
            HStack {
                Spacer()
                Text(Self.formatDuration(duration))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SolaroColor.textTertiary)
            }
        }
    }

    static func formatDuration(_ ms: Double) -> String {
        if ms < 1 { return String(format: "%.2f ms", ms) }
        if ms < 1000 { return String(format: "%.0f ms", ms) }
        return String(format: "%.2f s", ms / 1000)
    }
}

/// One captured output. `Equatable` on the output value alone, so
/// SwiftUI can skip re-evaluating it when something else in the
/// notebook changed — which is most of the time, since every stream
/// chunk of any running cell invalidates every row that reads
/// `notebook.cells`.
private struct ReplCellOutputView: View, Equatable {
    let output: ReplCellOutput

    var body: some View {
        switch output.kind {
        case .stream:
            Text((output.text ?? "").trimmingTrailingNewline)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(output.streamName == "stderr"
                                 ? SolaroColor.stateWarn
                                 : SolaroColor.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .result:
            resultView
        case .error:
            errorView
        }
    }

    @ViewBuilder
    private var resultView: some View {
        // Parsing happens once per distinct JSON payload, not once
        // per render — the result is a pure function of an immutable
        // string, and the view body runs on every keystroke-adjacent
        // event (GitLab #540).
        if let json = output.jsonValue,
           let table = ReplDisplayTableCache.table(for: json) {
            ReplDisplayTableView(table: table)
        } else if let plain = output.plainText, !plain.isEmpty {
            Text(plain.trimmingTrailingNewline)
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var errorView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(SolaroColor.stateError)
                Text(output.errorValue ?? "Execution failed")
                    .font(SolaroFont.monoCaption.weight(.semibold))
                    .foregroundStyle(SolaroColor.stateError)
                    .textSelection(.enabled)
            }
            if let traceback = output.traceback, traceback.count > 1 {
                Text(traceback.dropFirst().joined(separator: "\n"))
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .padding(SolaroSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SolaroRadius.s)
                .fill(SolaroColor.stateError.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.s)
                .stroke(SolaroColor.stateError.opacity(0.35), lineWidth: 1))
    }
}

private extension String {
    var trimmingTrailingNewline: String {
        var text = self
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

// MARK: - Tabular display

/// Native rendering of the display bundle's tabular shapes (the
/// server emits `text/html` tables for the same cases — a list of
/// records, a single record; we render from `application/json`
/// instead so the table is a real SOLARO surface, not a web view).
struct ReplDisplayTable: Equatable {
    var columns: [String]
    var rows: [[String]]
    /// Rows beyond the render cap, mentioned in the footer instead
    /// of silently dropped.
    var truncatedRowCount: Int = 0

    static let maxRows = 100
    static let maxColumns = 12

    /// Build a table when the JSON is a list of records or a single
    /// record; anything else (scalars, lists of scalars, deep
    /// nesting) returns nil and falls back to `text/plain` —
    /// mirroring the server's own "a one-column table is noise"
    /// rule.
    static func fromJSON(_ json: String) -> ReplDisplayTable? {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                  with: data, options: [.fragmentsAllowed])
        else { return nil }

        if let records = value as? [[String: Any]], !records.isEmpty {
            var columns: [String] = []
            for record in records {
                for key in record.keys.sorted() where !columns.contains(key) {
                    columns.append(key)
                }
            }
            guard columns.count <= maxColumns else { return nil }
            let visible = records.prefix(maxRows)
            let rows = visible.map { record in
                columns.map { cellText(record[$0]) }
            }
            return ReplDisplayTable(
                columns: columns, rows: rows,
                truncatedRowCount: max(0, records.count - maxRows))
        }

        if let record = value as? [String: Any], !record.isEmpty,
           record.count <= maxRows {
            let rows = record.keys.sorted().map { [$0, cellText(record[$0])] }
            return ReplDisplayTable(columns: ["Field", "Value"], rows: rows)
        }

        return nil
    }

    private static func cellText(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return "—"
        case let text as String:
            return text
        case let number as NSNumber:
            return "\(number)"
        case let nested:
            // Nested structures render compactly rather than
            // exploding the cell.
            if let data = try? JSONSerialization.data(
                withJSONObject: nested as Any,
                options: [.fragmentsAllowed, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return "\(nested ?? "—")"
        }
    }
}

/// Memo for `ReplDisplayTable.fromJSON`.
///
/// The parse — JSONSerialization, a column union, row
/// stringification — used to run inside the view body, so every
/// result table in the notebook re-parsed on every re-evaluation of
/// the outputs view: once per stream chunk of *any* running cell,
/// per selection change, per hover, per kernel-state change. With
/// a few 100×12 tables open that is visible jank in exactly the
/// data-exploration workflow the table exists for (GitLab #540).
///
/// The result is a pure function of an immutable string, so it is
/// cached by that string — nil results included, since "this JSON
/// isn't tabular" is just as expensive to rediscover. The cache is
/// small and FIFO-evicted: it exists to survive re-renders, not to
/// remember every table the session ever showed.
@MainActor
enum ReplDisplayTableCache {
    static let capacity = 32

    private static var entries: [String: ReplDisplayTable?] = [:]
    private static var order: [String] = []

    /// Real parses performed. Only interesting to tests, which
    /// assert the cache actually caches.
    private(set) static var parseCount = 0

    static func table(for json: String) -> ReplDisplayTable? {
        if let hit = entries[json] { return hit }
        let parsed = ReplDisplayTable.fromJSON(json)
        parseCount += 1
        entries[json] = parsed
        order.append(json)
        if order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
        return parsed
    }

    static func reset() {
        entries.removeAll()
        order.removeAll()
        parseCount = 0
    }
}

private struct ReplDisplayTableView: View {
    let table: ReplDisplayTable

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading,
                     horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(table.columns, id: \.self) { column in
                            Text(column)
                                .font(SolaroFont.monoCaption.weight(.semibold))
                                .foregroundStyle(SolaroColor.textSecondary)
                                .padding(.horizontal, SolaroSpace.s)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .background(SolaroColor.surfaceRaised)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { idx, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cellValue in
                                Text(cellValue)
                                    .font(SolaroFont.monoCaption)
                                    .foregroundStyle(SolaroColor.textPrimary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, SolaroSpace.s)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .background(idx.isMultiple(of: 2)
                                    ? Color.clear
                                    : SolaroColor.surfaceRaised.opacity(0.35))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
                .overlay(
                    RoundedRectangle(cornerRadius: SolaroRadius.s)
                        .stroke(SolaroColor.divider, lineWidth: 1))
            }
            if table.truncatedRowCount > 0 {
                Text("… \(table.truncatedRowCount) more rows")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
        }
    }
}
