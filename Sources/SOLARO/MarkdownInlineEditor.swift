// ============================================================
// MarkdownInlineEditor.swift
// SOLARO — hybrid rendered/raw markdown editor (#488)
// ============================================================
//
// A `.md` file opens rendered, not as source. Every block is shown
// with its markdown typography except the one the caret is in,
// which shows raw source and is editable. Moving the caret out
// re-renders the block just left and un-renders the one entered —
// Obsidian Live Preview / Typora / Bear behaviour.
//
// There is exactly one source of truth: the file text. The block
// list is derived from it (`MarkdownDocument`), the rendered views
// are derived from the block list, and every edit — typed
// characters, merges, undo — goes back through the buffer. Nothing
// holds a parallel copy that can drift.
//
// The two halves live elsewhere:
//   · `MarkdownDocument`             — buffer, blocks, ranges, undo
//   · `MarkdownBlockSourceEditor`    — the single raw-source field
//   · `BookMarkdownBlockView`        — the rendered blocks

import SwiftUI
import AppKit

// MARK: - Model

/// Editor state for one open markdown file.
///
/// A class, not `@State` structs, for two reasons: the AppKit block
/// editor's callbacks need a stable target, and `UndoManager`
/// registration needs one too.
@MainActor
@Observable
final class MarkdownEditorModel {

    /// The buffer + its block index.
    private(set) var doc: MarkdownDocument
    /// Id of the block currently shown as raw source, if any.
    private(set) var activeID: Int?
    /// Where to place the caret when the active block appears.
    private(set) var caretEntry: MarkdownCaretEntry = .end
    /// Set when the activation came from the keyboard, so the view
    /// scrolls the new block into sight. Clicks never scroll — the
    /// block is already under the pointer.
    private(set) var scrollToActive: Bool = false

    /// Pushes the buffer back out to the file binding.
    var onTextChange: (String) -> Void = { _ in }

    private var undoStack = MarkdownUndoStack()
    /// Suppresses undo recording while an undo/redo is being applied.
    private var restoring = false

    let undoManagerBridge = MarkdownDocumentUndoManager()

    init(text: String) {
        doc = MarkdownDocument(text: text)
        undoManagerBridge.model = self
    }

    // MARK: Derived

    var activeIndex: Int? {
        guard let activeID else { return nil }
        return doc.blocks.firstIndex { $0.id == activeID }
    }

    /// Raw markdown of the active block — what the source field shows.
    var activeSource: String {
        guard let index = activeIndex else { return "" }
        return doc.rawSource(at: index)
    }

    var canUndo: Bool { undoStack.canUndo }
    var canRedo: Bool { undoStack.canRedo }

    // MARK: External text

    /// The file changed underneath us (reload, AI edit, revert).
    /// Rebuilds from scratch — there is no edit in flight worth
    /// preserving when the bytes on disk moved.
    func adoptExternalText(_ text: String) {
        guard text != doc.text else { return }
        doc = MarkdownDocument(text: text)
        activeID = nil
    }

    /// Editing an empty file: there are no blocks to activate, so
    /// the whole (empty) buffer is the editing surface until the
    /// first character produces one.
    func replaceWholeDocument(_ text: String) {
        recordUndoStep(key: nil)
        doc = MarkdownDocument(text: text)
        onTextChange(doc.text)
        if activeID == nil, let last = doc.blocks.last {
            activeID = last.id
            caretEntry = .end
        }
    }

    // MARK: Activation

    /// Put the caret into `id`, re-rendering whichever block it was
    /// in. Both halves happen in one state update, so SwiftUI emits
    /// a single frame — the "no visible flicker" criterion.
    func activate(id: Int, entry: MarkdownCaretEntry, scroll: Bool = false) {
        if activeID == id {
            caretEntry = entry
            return
        }
        commitActive()
        guard doc.blocks.contains(where: { $0.id == id }) else { return }
        activeID = id
        caretEntry = entry
        scrollToActive = scroll
        undoStack.breakCoalescing()
    }

    /// Re-render the active block: re-parse its region so structural
    /// edits (a blank line splitting a paragraph, a `# ` promoting
    /// one to a heading) take effect, then drop the selection.
    func deactivate() {
        commitActive()
        activeID = nil
        scrollToActive = false
    }

    func clearScrollRequest() { scrollToActive = false }

    private func commitActive() {
        guard let index = activeIndex else { return }
        doc.reparse(around: index)
        undoStack.breakCoalescing()
    }

    // MARK: Editing

    /// A keystroke in the active block. Splices the new source into
    /// the buffer *without* re-splitting: re-parsing mid-word would
    /// yank the block out from under the caret. The re-split happens
    /// in `commitActive` when the caret leaves.
    func edit(_ newSource: String) {
        guard let index = activeIndex, let activeID else { return }
        recordUndoStep(key: "block-\(activeID)")
        guard doc.replaceSource(at: index, with: newSource) else { return }
        onTextChange(doc.text)
    }

    /// ⌫ at offset 0 — fold this block into the one above.
    func mergeBackward() {
        guard let index = activeIndex, index > 0 else { return }
        recordUndoStep(key: nil)
        guard let landed = doc.mergeWithPrevious(at: index) else { return }
        settle(on: landed)
    }

    /// ⌦ at the end — fold the block below into this one.
    func mergeForward() {
        guard let index = activeIndex else { return }
        recordUndoStep(key: nil)
        guard let landed = doc.mergeWithNext(at: index) else { return }
        settle(on: landed)
    }

    private func settle(on position: MarkdownCaretPosition) {
        guard doc.blocks.indices.contains(position.blockIndex) else {
            activeID = nil
            onTextChange(doc.text)
            return
        }
        activeID = doc.blocks[position.blockIndex].id
        caretEntry = .offset(position.offset)
        onTextChange(doc.text)
    }

    // MARK: Caret traversal across blocks

    /// ↑ / ← off the top edge of the active block.
    func moveToPreviousBlock(entry: MarkdownCaretEntry) {
        step(by: -1, entry: entry)
    }

    /// ↓ / → / ⇥ off the bottom edge.
    func moveToNextBlock(entry: MarkdownCaretEntry) {
        step(by: +1, entry: entry)
    }

    /// Walk one block in `direction`. The target is captured *by id*
    /// before committing, because committing re-parses and can
    /// renumber indices; the index is only the fallback for the rare
    /// case where the re-parse consumed the target block too.
    private func step(by direction: Int, entry: MarkdownCaretEntry) {
        guard let index = activeIndex else { return }
        let targetIndex = index + direction
        guard doc.blocks.indices.contains(targetIndex) else {
            // Already at the document edge — stay put rather than
            // dropping the caret out of the editor entirely.
            return
        }
        let targetID = doc.blocks[targetIndex].id
        commitActive()
        if doc.blocks.contains(where: { $0.id == targetID }) {
            activate(id: targetID, entry: entry, scroll: true)
        } else if let fallback = doc.blocks[
            safe: min(targetIndex, doc.blocks.count - 1)] {
            activate(id: fallback.id, entry: entry, scroll: true)
        }
    }

    // MARK: Undo

    /// Snapshot the buffer *before* a mutation. `key` groups a run
    /// of keystrokes in one block into a single undo step; nil
    /// forces a step of its own (merges, structural edits).
    private func recordUndoStep(key: String?) {
        guard !restoring else { return }
        let caret = currentCaret()
        undoStack.record(
            MarkdownSnapshot(text: doc.text,
                             caretLine: caret.line,
                             caretColumn: caret.column),
            key: key,
            at: Date().timeIntervalSinceReferenceDate)
        WorkspaceUndoRegistry.shared.noteUndoChange()
    }

    private func currentCaret() -> (line: Int, column: Int) {
        guard let index = activeIndex else { return (0, 0) }
        return doc.caretLineColumn(blockIndex: index,
                                   offset: caretEntry.resolve(in: activeSource))
    }

    func undo() {
        let caret = currentCaret()
        let current = MarkdownSnapshot(text: doc.text,
                                       caretLine: caret.line,
                                       caretColumn: caret.column)
        guard let previous = undoStack.undo(current: current) else { return }
        restore(previous)
    }

    func redo() {
        let caret = currentCaret()
        let current = MarkdownSnapshot(text: doc.text,
                                       caretLine: caret.line,
                                       caretColumn: caret.column)
        guard let next = undoStack.redo(current: current) else { return }
        restore(next)
    }

    private func restore(_ snapshot: MarkdownSnapshot) {
        restoring = true
        defer { restoring = false }
        doc = MarkdownDocument(text: snapshot.text)
        onTextChange(doc.text)
        if let position = doc.caretPosition(line: snapshot.caretLine,
                                            column: snapshot.caretColumn),
           doc.blocks.indices.contains(position.blockIndex) {
            activeID = doc.blocks[position.blockIndex].id
            caretEntry = .offset(position.offset)
            scrollToActive = true
        } else {
            activeID = nil
        }
        WorkspaceUndoRegistry.shared.noteUndoChange()
    }
}

/// Adapter that lets the workspace's ⌘Z drive document-level undo.
///
/// `SolaroUndoCommand` walks the responder chain for an `NSText`
/// and calls `undo()` on its `undoManager`. The markdown block
/// editor returns this object from `undoManager`, so the menu ends
/// up on `MarkdownEditorModel`'s buffer-level stack instead of a
/// per-block one that dies when the caret moves.
final class MarkdownDocumentUndoManager: UndoManager {
    weak var model: MarkdownEditorModel?

    override var canUndo: Bool { onMain { $0.canUndo } ?? false }
    override var canRedo: Bool { onMain { $0.canRedo } ?? false }
    override var undoMenuItemTitle: String { "Undo Markdown Edit" }
    override var redoMenuItemTitle: String { "Redo Markdown Edit" }

    override func undo() { _ = onMain { $0.undo() } }
    override func redo() { _ = onMain { $0.redo() } }

    /// `UndoManager`'s API is not main-actor isolated but the model
    /// is, and every real caller (the Edit menu, the responder
    /// chain) is on the main thread. Bail out rather than trap if
    /// something ever calls in from elsewhere — a disabled Undo item
    /// is a better outcome than a crash.
    private func onMain<T: Sendable>(
        _ body: (MarkdownEditorModel) -> T
    ) -> T? {
        guard Thread.isMainThread, let model else { return nil }
        return MainActor.assumeIsolated { body(model) }
    }
}

// MARK: - View

struct MarkdownInlineEditor: View {
    /// The file's text. Writing to it saves — the workspace's
    /// editable binding persists every change straight to disk, and
    /// markdown is excluded from format-on-save, so what lands on
    /// disk is byte-for-byte what the buffer holds.
    @Binding var text: String
    /// Base font size, shared with the code editor preference.
    var fontSize: CGFloat = 13

    @State private var model: MarkdownEditorModel

    init(text: Binding<String>, fontSize: CGFloat = 13) {
        _text = text
        self.fontSize = fontSize
        _model = State(initialValue: MarkdownEditorModel(text: text.wrappedValue))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.doc.blocks.isEmpty {
                        emptyDocumentEditor
                    } else {
                        ForEach(model.doc.blocks) { block in
                            row(for: block)
                                .id(block.id)
                        }
                    }
                    // Tail spacer so the last block can be clicked
                    // and scrolled comfortably above the pane edge.
                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, SolaroSpace.xl)
                .padding(.vertical, SolaroSpace.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.scrollToActive) { _, wants in
                guard wants, let id = model.activeID else { return }
                proxy.scrollTo(id, anchor: .center)
                model.clearScrollRequest()
            }
        }
        .background(SolaroColor.backdrop)
        .onAppear {
            model.onTextChange = { newValue in
                if text != newValue { text = newValue }
            }
        }
        .onChange(of: text) { _, newValue in
            model.adoptExternalText(newValue)
        }
    }

    /// An empty (or all-whitespace) file has no blocks to click, so
    /// the whole buffer becomes the editing surface until the first
    /// character produces one.
    private var emptyDocumentEditor: some View {
        MarkdownBlockSourceEditor(
            source: model.doc.text,
            fontSize: fontSize,
            entry: .end,
            actions: MarkdownBlockEditorActions(
                onEdit: { model.replaceWholeDocument($0) },
                undoManager: model.undoManagerBridge
            )
        )
        .frame(minHeight: 28)
    }

    @ViewBuilder
    private func row(for block: MarkdownSourceBlock) -> some View {
        if model.activeID == block.id {
            MarkdownBlockSourceEditor(
                source: model.activeSource,
                language: fenceLanguage(of: block),
                fontSize: fontSize,
                entry: model.caretEntry,
                actions: MarkdownBlockEditorActions(
                    onEdit: { model.edit($0) },
                    onExitUp: { model.moveToPreviousBlock(entry: $0) },
                    onExitDown: { model.moveToNextBlock(entry: $0) },
                    onMergeBackward: { model.mergeBackward() },
                    onMergeForward: { model.mergeForward() },
                    onDeactivate: { model.deactivate() },
                    undoManager: model.undoManagerBridge
                )
            )
            .overlay(alignment: .leading) {
                // Thin accent rail marking which block is live.
                Rectangle()
                    .fill(SolaroColor.accent)
                    .frame(width: 2)
                    .offset(x: -SolaroSpace.s)
            }
        } else {
            BookMarkdownBlockView(block: block.block, style: .editor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.activate(id: block.id, entry: .end)
                }
        }
    }

    /// Fence language for a code block, so the raw editor can
    /// highlight it while the caret is inside.
    private func fenceLanguage(of block: MarkdownSourceBlock) -> String? {
        if case .codeBlock(let language, _) = block.block { return language }
        return nil
    }
}

extension Array {
    /// Bounds-checked subscript. Used where an index was computed
    /// before a re-parse that may have shortened the array.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
