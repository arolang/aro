// ============================================================
// GraphSurface.swift
// SOLARO — pan and zoom, written once (#775)
// ============================================================
//
// Four views draw a graph: the statement canvas, the OpenAPI routes and
// schemas, the project map of feature sets, and the two-column graph
// diff. Three of them carried their own `pan`, `zoom`, `dragOffset` and
// `magnify`, their own drag and magnification gestures, and their own
// clamp — byte-for-byte the same code in three files. A fix to any of
// it survived in the other two.
//
// This is the shared surface: it owns the viewport, applies the
// transform to whatever content it is given, and installs the gestures
// over the whole pane so a drag starting on the empty backdrop pans
// like a drag starting on a node.
//
// Deliberately not the node/edge protocol the issue sketches. That
// would mean four renderers agreeing on what a node is, and they
// genuinely disagree — a statement card, a schema box, a feature-set
// row and a diff column are different shapes with different hit
// targets. The transform and the gestures are the part that is
// actually the same, and that is the part extracted.

import SwiftUI

/// Where a graph view is looking.
struct GraphViewport: Equatable {
    var pan: CGSize = .zero
    var zoom: Double = 1.0

    /// Far enough out to see a large application, far enough in to read
    /// a statement. The same range all three views had.
    static let zoomLimits: ClosedRange<Double> = 0.3...3.0

    mutating func pan(by translation: CGSize) {
        pan.width += translation.width
        pan.height += translation.height
    }

    mutating func magnify(by factor: Double) {
        zoom = min(max(zoom * factor, Self.zoomLimits.lowerBound),
                   Self.zoomLimits.upperBound)
    }

    /// Step the zoom, for a toolbar's plus and minus.
    mutating func zoom(by step: Double) {
        magnify(by: step)
    }

    mutating func reset() {
        self = GraphViewport()
    }
}

/// A pannable, zoomable pane with graph content in it.
///
/// Fills the space it is given and hit-tests all of it, so dragging the
/// empty backdrop pans. Overlays — zoom controls, empty-state notices,
/// legends — belong outside this view, where they stay unscaled.
struct GraphSurface<Content: View>: View {
    @Binding var viewport: GraphViewport
    /// False under Reduce Motion, where an animated zoom is the thing
    /// the setting exists to stop.
    var animatesZoom: Bool = true
    @ViewBuilder var content: Content

    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var magnification: Double = 1.0

    var body: some View {
        content
            .offset(x: viewport.pan.width + dragOffset.width,
                    y: viewport.pan.height + dragOffset.height)
            .scaleEffect(viewport.zoom * magnification, anchor: .topLeading)
            .animation(animatesZoom ? .easeOut(duration: 0.15) : nil,
                       value: viewport.zoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(panGesture)
            .gesture(magnifyGesture)
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                viewport.pan(by: value.translation)
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .updating($magnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                viewport.magnify(by: value)
            }
    }
}

/// `GraphSurface` as a modifier, for a view whose content is already
/// assembled and only needs the transform and the gestures put on it.
///
/// Same behaviour, reached a different way: some of these views build
/// their content inside a `GeometryReader` and want the viewport
/// applied to the result rather than wrapping a closure around it.
private struct GraphViewportModifier: ViewModifier {
    @Binding var viewport: GraphViewport
    var animatesZoom: Bool

    func body(content: Content) -> some View {
        GraphSurface(viewport: $viewport, animatesZoom: animatesZoom) {
            content
        }
    }
}

extension View {
    /// Pan and zoom this content, with the gestures over the whole pane.
    func graphViewport(_ viewport: Binding<GraphViewport>,
                       animatesZoom: Bool = true) -> some View {
        modifier(GraphViewportModifier(viewport: viewport,
                                       animatesZoom: animatesZoom))
    }
}
