// ============================================================
// ReplNotebookCommands.swift
// SOLARO — notebook cell clipboard + command-mode keys
// ============================================================
//
// The notebook shipped ⇧⏎ / ⌥⏎ / ⌘⏎ / Esc, which are Jupyter's
// chords — and nothing else was. With a cell merely *selected*
// every key was dead: no A/B to insert, no DD to delete, no M/Y to
// convert, no ↑/↓ to move between cells, and no clipboard at all,
// so reordering a thirty-cell course notebook meant clicking a
// one-step arrow in a hover toolbar thirty times (GitLab #538).
//
// This file holds the three pieces that were missing:
//
//   * ReplCellPasteboard — cells on the pasteboard as JSON under a
//     private type, with a plain-text flavour so a copied cell
//     pastes as source into any other editor.
//   * NotebookCellCommand / NotebookKeyRouter — the command-mode
//     key map, resolved through KeybindingStore so every key here
//     is remappable in Settings → Keybindings like the rest of the
//     app (GitLab #534's registry is the single source of truth).
//   * NotebookCommandKeys — the AppKit view that holds first
//     responder while command mode is on, turns key presses into
//     commands, and answers cut:/copy:/paste: so the Edit menu's
//     ⌘X/⌘C/⌘V act on the selected cell.

import SwiftUI
import AppKit

// MARK: - Pasteboard

enum ReplCellPasteboard {
    /// Private flavour carrying whole cells (kind, source, outputs).
    static let cellsType = NSPasteboard.PasteboardType("dev.aro.solaro.repl-cells")

    /// Write cells as JSON, plus their sources as plain text so a
    /// copied cell can be pasted into any other editor.
    static func write(_ cells: [ReplNotebookCell],
                      to pasteboard: NSPasteboard = .general) {
        guard !cells.isEmpty else { return }
        pasteboard.clearContents()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(cells) {
            pasteboard.setData(data, forType: cellsType)
        } else {
            // Cells are plain Codable values; a failure here would
            // mean something is very wrong, and losing the private
            // flavour silently would look like "copy did nothing".
            FileHandle.standardError.write(
                Data("[ReplNotebook] Warning: couldn't encode cells for the pasteboard\n".utf8))
        }
        pasteboard.setString(cells.map(\.source).joined(separator: "\n\n"),
                             forType: .string)
    }

    /// Cells from the pasteboard, or — when the pasteboard only has
    /// text — one code cell holding that text, so pasting from
    /// anywhere else still works. The `try?` is the whole point:
    /// pasteboard contents are foreign data, and a payload written
    /// by another app (or an older SOLARO) must fall through to the
    /// text flavour rather than fail the paste.
    static func read(from pasteboard: NSPasteboard = .general)
        -> [ReplNotebookCell] {
        if let data = pasteboard.data(forType: cellsType),
           let cells = try? JSONDecoder().decode([ReplNotebookCell].self, from: data),
           !cells.isEmpty {
            return cells
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return [ReplNotebookCell(kind: .code, source: text)]
        }
        return []
    }

    static func hasCells(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.data(forType: cellsType) != nil
            || (pasteboard.string(forType: .string)?.isEmpty == false)
    }
}

// MARK: - Clipboard operations

extension ReplNotebookController {

    func copyCell(_ id: String, to pasteboard: NSPasteboard = .general) {
        guard let idx = cellIndex(of: id) else { return }
        ReplCellPasteboard.write([cells[idx]], to: pasteboard)
    }

    func cutCell(_ id: String, to pasteboard: NSPasteboard = .general) {
        guard cellIndex(of: id) != nil else { return }
        copyCell(id, to: pasteboard)
        deleteCell(id)
    }

    /// Paste below `id` (below the selection when `id` is nil).
    @discardableResult
    func pasteCells(after id: String? = nil,
                    from pasteboard: NSPasteboard = .general) -> [String] {
        let incoming = ReplCellPasteboard.read(from: pasteboard)
        guard !incoming.isEmpty else { return [] }
        return insertCells(incoming, after: id ?? selectedCellID)
    }
}

// MARK: - Command-mode key map

/// One command-mode action. The raw value is its id in
/// `KeybindingRegistry`, so the shortcut is user-remappable.
enum NotebookCellCommand: String, CaseIterable {
    case selectAbove  = "notebook.selectCellAbove"
    case selectBelow  = "notebook.selectCellBelow"
    case editCell     = "notebook.editCell"
    case insertAbove  = "notebook.insertCellAbove"
    case insertBelow  = "notebook.insertCellBelow"
    case deleteCell   = "notebook.deleteCell"
    case toMarkdown   = "notebook.convertToMarkdown"
    case toCode       = "notebook.convertToCode"
    case mergeBelow   = "notebook.mergeCellBelow"
    case duplicate    = "notebook.duplicateCell"

    /// Jupyter's `DD`: destructive, so it takes two presses.
    var needsDoublePress: Bool { self == .deleteCell }
}

enum NotebookKeyRouter {

    /// The command bound to this combination, if any. Letters match
    /// case-insensitively — ⇧M arrives as "M" — and modifiers must
    /// match exactly, which is what keeps `M` (convert) and `⇧M`
    /// (merge) apart.
    @MainActor
    static func command(key: KeyEquivalent,
                        modifiers: EventModifiers,
                        store: KeybindingStore) -> NotebookCellCommand? {
        let typed = String(key.character).lowercased()
        for command in NotebookCellCommand.allCases {
            guard let binding = store.resolved(for: command.rawValue) else { continue }
            if String(binding.key.character).lowercased() == typed,
               binding.modifiers == modifiers {
                return command
            }
        }
        return nil
    }

    /// Arrow and return keys don't survive `characters`, so they
    /// come off the key code; everything else is the unmodified
    /// character.
    static func key(for event: NSEvent) -> KeyEquivalent? {
        switch event.keyCode {
        case 126: return .upArrow
        case 125: return .downArrow
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 36, 76: return .return
        case 53: return .escape
        case 51, 117: return .delete
        default:
            guard let ch = event.charactersIgnoringModifiers?.first,
                  !ch.isNewline else { return nil }
            return KeyEquivalent(Character(ch.lowercased()))
        }
    }

    static func modifiers(for event: NSEvent) -> EventModifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: EventModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift)   { mods.insert(.shift) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        return mods
    }
}

/// Two presses of the same key inside a window count as one
/// gesture — Jupyter's `DD` for delete, so a single stray `D`
/// never removes a cell.
struct DoublePressLatch {
    /// How long the first press stays armed.
    var window: TimeInterval = 1.2

    private var armedAt: TimeInterval?

    init(window: TimeInterval = 1.2) { self.window = window }

    /// Returns true on the *second* press inside the window, and
    /// disarms — a third press starts over.
    mutating func press(at now: TimeInterval) -> Bool {
        if let armedAt, now - armedAt <= window {
            self.armedAt = nil
            return true
        }
        armedAt = now
        return false
    }

    mutating func reset() { armedAt = nil }
}

// MARK: - Command-mode key view

/// Holds first responder while the notebook is in command mode and
/// routes key presses to cell commands. Also implements the
/// standard `cut:` / `copy:` / `paste:` actions, so the Edit menu's
/// ⌘X / ⌘C / ⌘V reach the selected cell through the responder chain
/// instead of being swallowed by a menu item with nowhere to go.
struct NotebookCommandKeys: NSViewRepresentable {
    var notebook: ReplNotebookController
    /// Command mode is on — take the keyboard.
    var active: Bool

    func makeNSView(context: Context) -> CommandKeyView {
        let view = CommandKeyView()
        view.notebook = notebook
        return view
    }

    func updateNSView(_ view: CommandKeyView, context: Context) {
        view.notebook = notebook
        guard active, let window = view.window,
              window.firstResponder !== view else { return }
        // Deferred: SwiftUI is mid-update, and AppKit dislikes a
        // responder change inside a layout pass.
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window?.firstResponder !== view else { return }
            view.window?.makeFirstResponder(view)
        }
    }

    @MainActor
    final class CommandKeyView: NSView, NSUserInterfaceValidations {
        var notebook: ReplNotebookController?
        private var deleteLatch = DoublePressLatch()

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard let notebook, notebook.commandMode,
                  let key = NotebookKeyRouter.key(for: event) else {
                super.keyDown(with: event)
                return
            }
            let modifiers = NotebookKeyRouter.modifiers(for: event)
            guard let command = NotebookKeyRouter.command(
                key: key, modifiers: modifiers, store: KeybindingStore.shared)
            else {
                super.keyDown(with: event)
                return
            }
            if command.needsDoublePress,
               !deleteLatch.press(at: event.timestamp) {
                return   // armed; the second press does the work
            }
            deleteLatch.reset()
            perform(command)
        }

        private func perform(_ command: NotebookCellCommand) {
            guard let notebook, let id = notebook.selectedCellID else { return }
            switch command {
            case .selectAbove:  notebook.selectCell(offset: -1)
            case .selectBelow:  notebook.selectCell(offset: 1)
            case .editCell:
                notebook.commandMode = false
                if notebook.cells.first(where: { $0.id == id })?.kind == .markdown {
                    notebook.editingMarkdownIDs.insert(id)
                }
            case .insertAbove:  notebook.addCell(kind: .code, before: id)
            case .insertBelow:  notebook.addCell(kind: .code, after: id)
            case .deleteCell:   notebook.deleteCell(id)
            case .toMarkdown:   notebook.convertCell(id, to: .markdown)
            case .toCode:       notebook.convertCell(id, to: .code)
            case .mergeBelow:   notebook.mergeCellBelow(id)
            case .duplicate:    notebook.duplicateCell(id)
            }
            // Inserting or converting to markdown opens an editor;
            // command mode is over the moment one takes focus.
            switch command {
            case .insertAbove, .insertBelow, .toMarkdown, .editCell:
                notebook.commandMode = false
            default:
                break
            }
        }

        // MARK: Responder-chain clipboard

        @objc func copy(_ sender: Any?) {
            guard let notebook, let id = notebook.selectedCellID else { return }
            notebook.copyCell(id)
        }

        @objc func cut(_ sender: Any?) {
            guard let notebook, let id = notebook.selectedCellID else { return }
            notebook.cutCell(id)
        }

        @objc func paste(_ sender: Any?) {
            notebook?.pasteCells()
        }

        func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            guard let notebook, notebook.commandMode else { return false }
            switch item.action {
            case #selector(copy(_:)), #selector(cut(_:)):
                return notebook.selectedCellID != nil
            case #selector(paste(_:)):
                return ReplCellPasteboard.hasCells()
            default:
                return true
            }
        }
    }
}
