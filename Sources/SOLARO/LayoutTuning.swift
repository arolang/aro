// ============================================================
// LayoutTuning.swift
// SOLARO — named, unit-bearing constants for the canvas layout
// engines (StackLayout + ForceDirectedLayout)
// ============================================================
//
// Background: the layout engines used to embed numeric constants
// inline at use sites — `rowPitch: Double = 104`, `area: Double =
// 600 * 600`, etc. — with no semantic name, no unit, and no
// docstring. Tweaking the canvas meant grep-and-guess across two
// files. That's GitLab issue #312.
//
// This struct collects every dial both engines turn into one
// named place. Each field carries its unit in the comment so a
// future maintainer can change it without having to read the
// layout body to learn what `0.95` measured.

import Foundation

/// All numeric knobs the canvas layout engines respect. Pass an
/// instance through `StackLayout.place(_:tuning:)` /
/// `ForceDirectedLayout.place(_:tuning:)`; use `.default` for the
/// shipping values.
struct LayoutTuning: Sendable {

    // MARK: — Statement-node geometry (StackLayout)

    /// Width assumed for a statement-node card during auto-layout.
    /// Must stay in sync with `CanvasView.nodeWidth` so overlap
    /// resolution uses the same box the renderer draws.
    /// Unit: SwiftUI points.
    var assumedNodeWidth: Double = 240

    /// Height assumed for a statement-node card during auto-layout.
    /// Sync with `CanvasView.nodeHeight`. Unit: SwiftUI points.
    var assumedNodeHeight: Double = 84

    /// Padding the feature-set container draws around its child
    /// nodes (see `FeatureSetContainersLayer.groupedFeatureSets`).
    /// Mirrored here so overlap detection uses the same rect the
    /// renderer paints, otherwise resolving "no node overlap"
    /// would still leave visible container borders crossing
    /// through cards. Unit: SwiftUI points.
    var fsContainerInset: Double = 14

    /// Extra space the feature-set container leaves at the top for
    /// its header strip. Unit: SwiftUI points.
    var fsContainerHeaderExtra: Double = 28

    // MARK: — Stack layout pitch

    /// Vertical distance between successive rows inside a feature
    /// set. Defaults to `assumedNodeHeight (84) + 20pt gap`.
    /// Unit: SwiftUI points.
    var rowPitch: Double = 104

    /// Horizontal distance between successive columns inside a
    /// feature set. Unit: SwiftUI points.
    var columnPitch: Double = 320

    /// Horizontal gap between the rightmost column of one feature
    /// set and the leftmost column of the next. Unit: SwiftUI
    /// points.
    var featureSetGap: Double = 80

    /// X offset of the first feature set's left edge from the
    /// canvas origin. Unit: SwiftUI points.
    var leftPadding: Double = 40

    /// Y offset of the first node row from the canvas origin. Big
    /// enough that the feature-set container's top edge (which
    /// sits `inset + headerExtra` = 42pt above the first node)
    /// lands well below the file-tab + breadcrumb strips the
    /// workspace stacks on top of the canvas. Previously 56,
    /// which crowded the breadcrumb row. Unit: SwiftUI points.
    var topPadding: Double = 110

    /// Horizontal gap between the rightmost laid-out node column
    /// and the repository column. Unit: SwiftUI points.
    var repoColumnGap: Double = 120

    /// Vertical pitch between successive repository entities in
    /// the repository column. Unit: SwiftUI points.
    var repoRowPitch: Double = 96

    // MARK: — Force-directed layout

    /// Square root of the bounding-box area for the
    /// Fruchterman-Reingold solver. Default 600² → 360 000 unit²
    /// → 600pt side. Unit: SwiftUI points squared.
    var forceDirectedArea: Double = 600 * 600

    /// Number of solver iterations. Higher values converge tighter
    /// at quadratic cost. 60 ticks is enough to settle a graph of
    /// ~40 nodes from a circle seed.
    var forceDirectedIterations: Int = 60

    /// Linear cooling factor applied to the temperature at the end
    /// of each iteration. Dimensionless; in `(0, 1)`. 0.95 means
    /// 60 iterations halve the max displacement roughly 4×.
    var forceDirectedCooling: Double = 0.95

    /// Numerical floor for distance / magnitude calculations so a
    /// pair of coincident nodes doesn't divide by zero. Unit:
    /// SwiftUI points.
    var forceDirectedEpsilon: Double = 0.01

    /// Soft margin around the canvas inside which placed nodes
    /// stay clamped. Prevents the solver from pushing nodes off
    /// the visible canvas. Unit: SwiftUI points.
    var forceDirectedMargin: Double = 20

    // MARK: — Defaults

    /// Shipping values. Don't mutate; copy and override fields you
    /// want to change.
    static let `default` = LayoutTuning()
}
