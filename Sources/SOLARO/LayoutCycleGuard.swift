// ============================================================
// LayoutCycleGuard.swift
// SOLARO — centralised macOS-26 layout-cycle defenses (#301)
// ============================================================
//
// This file is the single home for the workarounds SOLARO carries
// against the macOS 26 "more update-constraints passes than views"
// hard-assert. Before #301 the same defense was copy-pasted across
// three panes (Inspector, the OpenAPI canvas, and the workspace
// detail column) with a paragraph of rationale duplicated at each
// site. It now lives here once.
//
// There are TWO distinct triggers for the same underlying abort, and
// they need TWO different defenses. Both are documented here so the
// coupling is visible in one place.
//
// -----------------------------------------------------------------
// 1. SwiftUI ideal-size feedback → `layoutCycleGuard()`
// -----------------------------------------------------------------
// An @Observable-driven SwiftUI subtree that declares an explicit
// ideal size (an OpenAPI canvas sized to its content, an inspector
// whose sections expand/contract on every controller mutation, the
// tab-bar / breadcrumb / center-pane stack) feeds that ideal size
// into the `NSHostingView` hosting the split-view column. AppKit's
// `SplitViewChildController.hostingController_didUpdateMinSize_maxSize`
// reads it and re-enqueues a layout pass per render; on macOS 26 the
// constraint-cycle guard eventually aborts the process (the same
// hard-assert the `.metrics` window works around with a raw AppKit
// panel — see Workspace.swift).
//
// Hosting the content inside `Color.clear.overlay { content }` breaks
// the size-propagation pipe: `Color.clear` becomes the layout-
// defining child with a flexible ideal size, so the column's ideal
// size stays "fill available", `NSHostingView`'s min/max stops
// churning, and `SplitViewChildController` stops re-entering. The
// content still renders at its intended geometry as the overlay.
//
// -----------------------------------------------------------------
// 2. STTextView KVO-during-layout → the guards in CodeEditor.swift
// -----------------------------------------------------------------
// STTextView 2.3.10's `setupTextLayoutManager` installs a KVO
// observer on `NSTextLayoutManager.usageBoundsForTextContainer` that
// fires *inside* the layout pass and re-invalidates layout — an
// infinite layout loop that trips the same macOS-26 abort from a
// different direction. `AROHoverTextView` breaks that loop with a
// cluster of overrides (`layout()` re-entrance guard, `needsLayout`
// filter, `invalidateIntrinsicContentSize()` guard) plus a
// `sizeThatFits` on the representable. Those live next to the text
// view they patch; they can't move here because they're `NSView`
// overrides, but they share this file's retirement criteria.
//
// -----------------------------------------------------------------
// Retirement (do NOT rip these out speculatively — #301)
// -----------------------------------------------------------------
// Both defenses are pinned to `STTextViewCoupling.knownVersion`. The
// upstream fix pattern is `STTextViewCoupling.upstreamFixPR`. To
// retire:
//   1. Bump `from:` for STTextView in Package.swift past 2.3.10 once
//      a release ships the PR #102 fix.
//   2. Re-test split mode (HSplitView with the editor), inspector
//      file-selection churn, and the OpenAPI canvas on macOS 26.
//   3. If stable, remove the STTextView overrides in CodeEditor.swift
//      AND replace each `.layoutCycleGuard(...)` call with its inner
//      content, then delete this file.
// Until a release past 2.3.10 exists, the guards stay — 2.3.10 is
// still the latest tag, so there is nothing to migrate to yet.

import SwiftUI

/// Single source of truth for the STTextView / macOS-26 version
/// coupling that `layoutCycleGuard()` and the `CodeEditor.swift`
/// overrides both work around. Update this alongside the `from:`
/// bump in Package.swift.
enum STTextViewCoupling {
    /// The STTextView release these workarounds are validated against.
    /// Matches the `from:` constraint in Package.swift.
    static let knownVersion = "2.3.10"

    /// Upstream fix pattern for the NavigationSplitView invalidation
    /// loop. When a release past `knownVersion` includes it, follow
    /// the retirement checklist at the top of this file.
    static let upstreamFixPR =
        "https://github.com/krzyzanowskim/STTextView/pull/102"
}

extension View {
    /// Wrap `self` in the macOS-26 layout-cycle defense: render it as
    /// an overlay on top of a `Color.clear` base so the base — not the
    /// content's explicit ideal size — defines this subtree's layout
    /// size. Breaks the `SplitViewChildController` ideal-size feedback
    /// loop documented at the top of this file (#301).
    ///
    /// - Parameter alignment: how the content is aligned within the
    ///   clear base. Defaults to `.center`; canvas-style content that
    ///   draws from the top-left passes `.topLeading`.
    func layoutCycleGuard(alignment: Alignment = .center) -> some View {
        Color.clear.overlay(alignment: alignment) { self }
    }
}
