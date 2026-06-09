// ============================================================
// ConstantSizeHost.swift
// SOLARO — NSViewRepresentable that hides SwiftUI size changes
// ============================================================
//
// macOS 26's `SplitViewChildController` hard-asserts when a child
// SwiftUI subtree invalidates its min/max size while the window's
// constraint-update pass is in flight. SwiftUI's metrics panel
// re-renders on every snapshot (1 Hz here) — feature-set rows are
// added, numbers change width — and each re-render bubbles a size
// invalidation up through `NSHostingView.SizeConstraints.update(_)`
// → `SplitViewChildController.hostingView(_:didUpdateMinSize:…)`
// → SIGABRT.
//
// This wrapper sits between the inspector column and the SwiftUI
// content: the outer `NoIntrinsicSizeView` reports
// `noIntrinsicMetric`, the inner `NSHostingView` is pinned to fill
// it, and SwiftUI re-renders happen entirely within the wrapper
// without touching the split view's constraints.

import SwiftUI
import AppKit

struct ConstantSizeHost<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NoIntrinsicSizeView()
        let host = NSHostingController(rootView: content)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.host = host
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.host?.rootView = content
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var host: NSHostingController<Content>?
    }
}

/// Reports `noIntrinsicMetric` so the split-view column above can't
/// observe size changes from the SwiftUI subtree inside. The view's
/// actual size is dictated by its superview's constraints, not by
/// content.
final class NoIntrinsicSizeView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: NSView.noIntrinsicMetric)
    }
}
