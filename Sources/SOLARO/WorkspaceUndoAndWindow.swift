// ============================================================
// WorkspaceUndoAndWindow.swift
// SOLARO — UndoManager registry + window/responder shims
// ============================================================
//
// Extracted from Workspace.swift (#289 step 2). Owns:
//
// * WorkspaceWindowSizer — clamps the window's minimum size
//   based on which panels are shown.
// * WorkspaceWindowUndoBinder — pushes the workspace's
//   UndoManager onto the NSWindow's first responder chain.
// * SolaroUndoManagerKey — custom EnvironmentKey replacement for
//   SwiftUI's non-writable \\.undoManager slot.
// * WorkspaceUndoRegistry — singleton tracking the front-most
//   workspace's UndoManager so Edit menu commands route there.

import SwiftUI
import AppKit

struct WorkspaceWindowSizer: NSViewRepresentable {
    let sidebarShown: Bool
    let inspectorShown: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        let width: CGFloat = {
            switch (sidebarShown, inspectorShown) {
            case (true,  true):  return 1200  // sidebar + center + inspector
            case (true,  false): return 800   // sidebar + center
            case (false, true):  return 900   // center + inspector
            case (false, false): return 700   // center only
            }
        }()
        let target = NSSize(width: width, height: 800)
        guard window.contentMinSize != target else { return }
        window.contentMinSize = target
        // If the window is currently below the new floor, snap it up
        // so layout never lands in the auto-collapse band.
        var frame = window.frame
        let extraH = frame.height - window.contentLayoutRect.height
        let needW = max(frame.width, target.width)
        let needH = max(frame.height, target.height + extraH)
        if needW != frame.width || needH != frame.height {
            frame.size = NSSize(width: needW, height: needH)
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

/// Walks up from a SwiftUI background view to the hosting NSWindow
/// and installs `manager` as the window delegate's "return undo
/// manager" so AppKit's standard responder chain — the one Edit →
/// Undo and ⌘Z route through — finds it whenever no first
/// responder in the chain has its own (e.g. when the canvas is
/// focused). STTextView still gets character-level undo via its
/// own first-responder undoManager because the chain consults the
/// responder before the window delegate.
struct WorkspaceWindowUndoBinder: NSViewRepresentable {
    let manager: UndoManager

    func makeNSView(context: Context) -> NSView {
        // No-op placeholder. We don't actually install the
        // UndoManager via the window delegate any more — SwiftUI
        // races us for that slot and overwriting it breaks SwiftUI's
        // own window plumbing. Instead `SolaroUndoCommand` picks
        // the right manager at click time by walking the responder
        // chain itself. Leaving this view in place so the call
        // site stays unchanged.
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        let manager: UndoManager
        init(manager: UndoManager) { self.manager = manager }
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
            manager
        }
    }
}

/// Custom Environment key for the workspace's UndoManager. SwiftUI
/// 6 made the built-in `\.undoManager` read-only, so canvas code
/// pulls the manager from this key instead.
struct SolaroUndoManagerKey: EnvironmentKey {
    static let defaultValue: UndoManager? = nil
}
extension EnvironmentValues {
    var solaroUndoManager: UndoManager? {
        get { self[SolaroUndoManagerKey.self] }
        set { self[SolaroUndoManagerKey.self] = newValue }
    }
}

/// Process-wide registry that knows which workspace's UndoManager
/// the app-level Edit-menu commands should act on. We use this
/// instead of `@FocusedValue` because that route was returning nil
/// inside `CommandGroup` closures — the menu items stayed disabled
/// even after a successful registerUndo, because the focused-scene
/// value wasn't propagating into the CommandGroup builder.
///
/// `WorkspaceView` pushes its manager on appear and pops it on
/// disappear. The most-recently-pushed manager is treated as the
/// "current" one — close enough for single-window flows, and a
/// reasonable approximation for multi-window (the front window
/// generally pushed most recently).
@Observable
@MainActor
final class WorkspaceUndoRegistry {
    static let shared = WorkspaceUndoRegistry()
    private init() {}
    /// LIFO stack of managers. `current` is the last one pushed.
    /// Stored as a tuple of (instance pointer, manager) so a
    /// pop matches by identity even after the manager mutates.
    private var stack: [UndoManager] = []
    /// Bumped on every push / pop / undo-stack notification so
    /// SwiftUI command bodies that read this registry re-render.
    private(set) var tick: UInt64 = 0
    var current: UndoManager? { stack.last }

    func push(_ mgr: UndoManager) {
        stack.append(mgr)
        tick &+= 1
    }
    func pop(_ mgr: UndoManager) {
        if let idx = stack.lastIndex(where: { $0 === mgr }) {
            stack.remove(at: idx)
        }
        tick &+= 1
    }
    /// Called when an UndoManager fires its change notification so
    /// the menu items re-evaluate `canUndo` / `canRedo`.
    func noteUndoChange() { tick &+= 1 }
}

