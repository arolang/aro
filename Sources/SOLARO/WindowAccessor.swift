// ============================================================
// WindowAccessor.swift
// SOLARO — the NSWindow hosting a SwiftUI view (GitLab #744)
// ============================================================
//
// Menu actions are delivered as one broadcast notification, and every mounted
// `WorkspaceView` used to act on it. With two project windows open, Run,
// Debug, Test, Stop, Commit, Format Document, Graph Diff — and the destructive
// Delete File and Git: Revert Local Changes — fired in both.
//
// SwiftUI has no first-class "am I the key window", so this reaches for the
// hosting `NSWindow` once and hands it back. `@Environment(\.controlActiveState)`
// would be lighter but answers a different question: it reports `.inactive`
// for a window that is merely not frontmost, which is also true of the only
// window of a backgrounded app.

import AppKit
import SwiftUI

/// Reports the `NSWindow` hosting this part of the view tree.
///
/// Use as a zero-size background:
///
///     .background(WindowAccessor(window: $hostWindow))
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view has no window until it is in the hierarchy, so read it on
        // the next turn of the run loop rather than here.
        DispatchQueue.main.async { [weak view] in
            window = view?.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // A window can arrive late (a tab pulled into its own window, a
        // restored session), so keep the binding in step.
        DispatchQueue.main.async { [weak nsView] in
            guard let current = nsView?.window, current !== window else { return }
            window = current
        }
    }
}

extension NSWindow {
    /// Should this window act on a broadcast menu action?
    ///
    /// Exactly one window answers `true`: the key one. A `nil` receiver — the
    /// accessor has not attached yet, or there is no window at all, as when a
    /// test drives the view — answers `true` so the action is not silently
    /// dropped in the single-window case that has always worked.
    static func shouldHandleMenuAction(receiver: NSWindow?) -> Bool {
        guard let receiver else { return true }
        guard let key = NSApp.keyWindow else { return false }
        return receiver === key
    }
}
