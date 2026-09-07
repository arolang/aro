// ============================================================
// GraphDiffHTMLReport.swift
// ARO CLI — `aro diff --graph --html` (GitLab #443)
// ============================================================
//
// The report a merge request links to: the application's feature
// graph at both revisions, side by side, nodes bordered by what
// happened to them and wired by the events, calls and repository
// observers that connect them.
//
// Both panels are laid out from the *union* of the two revisions
// (see `FeatureGraphLayout`), so a feature set sits at the same
// coordinates on the left and the right and the eye can track it
// straight across. A node missing from one side is drawn there as
// a dashed ghost rather than omitted — otherwise the two panels
// would drift out of alignment exactly where the change is.
//
// Self-contained by construction: inline CSS, inline SVG, one
// inline script, no fonts or images fetched. A CI job can keep the
// file as an artifact and it will render from a `file://` URL with
// no network at all.

import Foundation
import AROParser

enum GraphDiffHTMLReport {

    // Node box geometry, shared by the layout maths and the SVG.
    private static let nodeWidth = 208.0
    private static let nodeHeight = 52.0
    private static let gapX = 28.0
    private static let gapY = 74.0
    private static let margin = 18.0

    static func render(range: String,
                       diff: FeatureGraphDiff,
                       includeUnchanged: Bool = false) -> String
    {
        let nodes = includeUnchanged ? diff.nodes : diff.touchedNodes
        let layout = FeatureGraphLayout.compute(diff, nodes: nodes)

        let body: String
        if nodes.isEmpty {
            body = "<p class=\"empty\">No feature-set changes.</p>"
        } else {
            body = """
            <div class="panels">
            \(panel(title: diff.beforeLabel, side: .before,
                    diff: diff, nodes: nodes, layout: layout))
            \(panel(title: diff.afterLabel, side: .after,
                    diff: diff, nodes: nodes, layout: layout))
            </div>
            \(wireSection(diff))
            \(detailSection(nodes))
            """
        }

        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>ARO graph diff — \(escape(range))</title>
        <style>\(stylesheet)</style></head><body>
        <header>
          <h1>ARO graph diff <code>\(escape(range))</code></h1>
          <p class="summary">\(escape(diff.summaryLine))</p>
          \(legend)
        </header>
        \(body)
        <script>\(script)</script>
        </body></html>
        """
    }

    // MARK: - Graph panels

    private enum Side {
        case before, after

        var label: String { self == .before ? "before" : "after" }
    }

    private static func present(_ node: FeatureGraphDiff.NodeDiff, on side: Side) -> Bool {
        switch side {
        case .before: return node.change != .added
        case .after:  return node.change != .removed
        }
    }

    private static func present(_ entry: FeatureGraphDiff.EdgeDiff, on side: Side) -> Bool {
        switch side {
        case .before: return entry.change != .added
        case .after:  return entry.change != .removed
        }
    }

    private static func panel(title: String,
                              side: Side,
                              diff: FeatureGraphDiff,
                              nodes: [FeatureGraphDiff.NodeDiff],
                              layout: FeatureGraphLayout) -> String
    {
        """
        <section class="panel" data-side="\(side.label)">
          <h2>\(escape(title))</h2>
          <div class="canvas">
        \(svg(side: side, diff: diff, nodes: nodes, layout: layout))
          </div>
        </section>
        """
    }

    private static func svg(side: Side,
                            diff: FeatureGraphDiff,
                            nodes: [FeatureGraphDiff.NodeDiff],
                            layout: FeatureGraphLayout) -> String
    {
        let width = margin * 2 + Double(max(layout.widestLayer, 1)) * (nodeWidth + gapX) - gapX
        let height = margin * 2 + Double(max(layout.layerCount, 1)) * (nodeHeight + gapY) - gapY

        var svg = "<svg viewBox=\"0 0 \(int(width)) \(int(height))\" "
            + "width=\"\(int(width))\" height=\"\(int(height))\" "
            + "role=\"img\" aria-label=\"Feature graph, \(escape(side.label)) revision\">"
        svg += arrowMarkers

        // Wires first so node boxes sit on top of them. An
        // endpoint that isn't drawn — or a name several drawn nodes
        // share — has no place to land, so its wire is left out.
        for entry in diff.edges where present(entry, on: side) {
            guard let from = layout.placement(named: entry.edge.from),
                  let to = layout.placement(named: entry.edge.to) else { continue }
            svg += wire(from: from, to: to, entry: entry)
        }

        for node in nodes {
            guard let placement = layout.placement(of: node.id) else { continue }
            svg += box(node, placement: placement, side: side,
                       present: present(node, on: side))
        }

        svg += "</svg>"
        return svg
    }

    private static func origin(_ placement: FeatureGraphLayout.Placement) -> (x: Double, y: Double) {
        (margin + Double(placement.column) * (nodeWidth + gapX),
         margin + Double(placement.layer) * (nodeHeight + gapY))
    }

    private static func box(_ node: FeatureGraphDiff.NodeDiff,
                            placement: FeatureGraphLayout.Placement,
                            side: Side,
                            present: Bool) -> String
    {
        let (x, y) = origin(placement)
        let colorClass = present ? node.change.rawValue : "ghost"
        // Each side shows its own activity: a feature set that was
        // re-pointed at another trigger reads as the change it is.
        let activity = side == .before
            ? (node.previousBusinessActivity ?? node.businessActivity)
            : node.businessActivity
        let title = present
            ? "\(node.name) — \(activity) (\(node.change.rawValue))"
            : "\(node.name) — not present at this revision"

        var group = "<g class=\"node \(colorClass)\" data-node=\"\(attribute(slug(node.id)))\" "
            + "tabindex=\"0\" onclick=\"aroFocus('\(attribute(slug(node.id)))')\">"
        group += "<title>\(escape(title))</title>"
        group += "<rect x=\"\(int(x))\" y=\"\(int(y))\" "
            + "width=\"\(int(nodeWidth))\" height=\"\(int(nodeHeight))\" rx=\"8\"/>"
        group += "<text class=\"name\" x=\"\(int(x + 12))\" y=\"\(int(y + 21))\">"
            + escape(truncate(node.name, 26)) + "</text>"
        group += "<text class=\"meta\" x=\"\(int(x + 12))\" y=\"\(int(y + 38))\">"
            + escape(truncate(activity, 24)) + " · " + node.kind.label
            + "</text>"
        group += "</g>"
        return group
    }

    private static func wire(from: FeatureGraphLayout.Placement,
                             to: FeatureGraphLayout.Placement,
                             entry: FeatureGraphDiff.EdgeDiff) -> String
    {
        let (fx, fy) = origin(from)
        let (tx, ty) = origin(to)
        let x1 = fx + nodeWidth / 2
        let y1 = fy + nodeHeight
        let x2 = tx + nodeWidth / 2
        let y2 = ty
        let path = "M \(int(x1)) \(int(y1)) C \(int(x1)) \(int(y1 + gapY / 2)), "
            + "\(int(x2)) \(int(y2 - gapY / 2)), \(int(x2)) \(int(y2))"
        let kind = entry.change.rawValue
        var out = "<path class=\"wire \(kind)\" d=\"\(path)\" "
            + "marker-end=\"url(#arrow-\(kind))\"><title>"
            + escape("\(entry.edge.from) \(entry.edge.kind.rawValue)"
                     + "(\(entry.edge.label)) → \(entry.edge.to) [\(kind)]")
            + "</title></path>"
        // Label the wire at its midpoint — an event name is the
        // whole reason the wire exists.
        out += "<text class=\"wirelabel \(kind)\" x=\"\(int((x1 + x2) / 2 + 6))\" "
            + "y=\"\(int((y1 + y2) / 2))\">\(escape(truncate(entry.edge.label, 20)))</text>"
        return out
    }

    private static let arrowMarkers: String = {
        GraphChange.allCases.map { change in
            """
            <marker id="arrow-\(change.rawValue)" viewBox="0 0 10 10" refX="9" refY="5" \
            markerWidth="6" markerHeight="6" orient="auto-start-reverse">\
            <path class="head \(change.rawValue)" d="M 0 0 L 10 5 L 0 10 z"/></marker>
            """
        }.joined()
    }()

    // MARK: - Wire list and per-node detail

    private static func wireSection(_ diff: FeatureGraphDiff) -> String {
        let changed = diff.edges.filter { $0.change != .unchanged }
        guard !changed.isEmpty else { return "" }
        var rows = ""
        for entry in changed {
            let symbol = entry.change == .added ? "+" : "−"
            rows += "<li class=\"\(entry.change.rawValue)\"><code>\(symbol) "
                + escape(entry.edge.from) + " ──" + entry.edge.kind.rawValue
                + "(" + escape(entry.edge.label) + ")──▶ " + escape(entry.edge.to)
                + "</code></li>"
        }
        return """
        <section class="wires">
          <h2>Wires that moved</h2>
          <ul>\(rows)</ul>
        </section>
        """
    }

    private static func detailSection(_ nodes: [FeatureGraphDiff.NodeDiff]) -> String {
        var cards = ""
        for node in nodes {
            cards += "<article class=\"fs \(node.change.rawValue)\" "
                + "id=\"node-\(attribute(slug(node.id)))\">"
            cards += "<h3>\(escape(node.name))"
            cards += "<span class=\"activity\">\(escape(node.businessActivity))</span>"
            cards += "<span class=\"badge\">\(node.change.rawValue)</span></h3>"
            cards += "<p class=\"where\">\(escape(location(node)))</p>"
            if let previous = node.previousBusinessActivity {
                cards += "<p class=\"where\">activity: \(escape(previous)) → "
                    + escape(node.businessActivity) + "</p>"
            }
            for statement in node.statements {
                let cssClass = statement.change.rawValue
                switch statement.change {
                case .modified:
                    cards += "<div class=\"stmt modified\">"
                    cards += "<del>\(escape(statement.before ?? ""))</del>"
                    cards += "<ins>\(escape(statement.after ?? ""))</ins></div>"
                case .added:
                    cards += "<div class=\"stmt \(cssClass)\">+ \(escape(statement.after ?? ""))</div>"
                case .removed:
                    cards += "<div class=\"stmt \(cssClass)\">− \(escape(statement.before ?? ""))</div>"
                case .unchanged:
                    cards += "<div class=\"stmt \(cssClass)\">\(escape(statement.display))</div>"
                }
            }
            cards += "</article>"
        }
        return """
        <section class="details">
          <h2>Feature sets</h2>
          \(cards)
        </section>
        """
    }

    private static func location(_ node: FeatureGraphDiff.NodeDiff) -> String {
        if node.movedFile {
            return "moved: \(node.beforeFile ?? "?") → \(node.afterFile ?? "?")"
        }
        return node.file
    }

    // MARK: - Chrome

    private static let legend = """
    <ul class="legend">
      <li><span class="swatch added"></span>added</li>
      <li><span class="swatch removed"></span>removed</li>
      <li><span class="swatch modified"></span>modified</li>
      <li><span class="swatch unchanged"></span>unchanged</li>
      <li><span class="swatch ghost"></span>absent at this revision</li>
    </ul>
    """

    private static let stylesheet = """
    :root {
      color-scheme: light dark;
      --added: #3fb950; --removed: #f85149; --modified: #d29922;
      --unchanged: #8b949e; --line: #8884;
    }
    body { font: 14px/1.5 ui-sans-serif, system-ui, sans-serif;
           margin: 0 auto; max-width: 78rem; padding: 2rem 1.5rem; }
    h1 { font-size: 1.3rem; }
    h2 { font-size: .95rem; text-transform: uppercase; letter-spacing: .08em;
         opacity: .7; }
    .summary { opacity: .75; font-size: .9rem; }
    .legend { display: flex; gap: 1rem; list-style: none; padding: 0;
              font-size: .78rem; opacity: .8; flex-wrap: wrap; }
    .legend li { display: flex; align-items: center; gap: .35rem; }
    .swatch { width: .8rem; height: .8rem; border-radius: 3px;
              border: 2px solid var(--unchanged); }
    .swatch.added { border-color: var(--added); }
    .swatch.removed { border-color: var(--removed); }
    .swatch.modified { border-color: var(--modified); }
    .swatch.ghost { border-style: dashed; opacity: .5; }
    .panels { display: flex; gap: 1rem; align-items: flex-start; }
    .panel { flex: 1 1 0; min-width: 0; }
    .canvas { overflow: auto; border: 1px solid var(--line); border-radius: 8px;
              padding: .5rem; }
    svg { display: block; }
    .node rect { fill: color-mix(in srgb, var(--unchanged) 12%, transparent);
                 stroke: var(--unchanged); stroke-width: 2; }
    .node text.name { font: 600 13px ui-sans-serif, system-ui, sans-serif;
                      fill: currentColor; }
    .node text.meta { font: 10px ui-monospace, monospace; fill: currentColor;
                      opacity: .6; }
    .node.added rect { stroke: var(--added);
                       fill: color-mix(in srgb, var(--added) 14%, transparent); }
    .node.removed rect { stroke: var(--removed);
                         fill: color-mix(in srgb, var(--removed) 14%, transparent); }
    .node.modified rect { stroke: var(--modified);
                          fill: color-mix(in srgb, var(--modified) 14%, transparent); }
    .node.ghost rect { stroke-dasharray: 5 4; fill: none; opacity: .45; }
    .node.ghost text { opacity: .35; }
    .node { cursor: pointer; }
    .node.selected rect { stroke-width: 3.5; }
    .wire { fill: none; stroke: var(--unchanged); stroke-width: 1.6; opacity: .8; }
    .wire.added { stroke: var(--added); }
    .wire.removed { stroke: var(--removed); stroke-dasharray: 5 4; }
    .head { fill: var(--unchanged); }
    .head.added { fill: var(--added); }
    .head.removed { fill: var(--removed); }
    .wirelabel { font: 10px ui-monospace, monospace; fill: currentColor; opacity: .6; }
    .wires ul { list-style: none; padding: 0; }
    .wires code { font-size: .8rem; }
    .wires li.added code { color: var(--added); }
    .wires li.removed code { color: var(--removed); }
    .fs { border-left: 3px solid var(--unchanged); padding-left: .8rem;
          margin: 1rem 0; scroll-margin-top: 1rem; }
    .fs.added { border-color: var(--added); }
    .fs.removed { border-color: var(--removed); }
    .fs.modified { border-color: var(--modified); }
    .fs.selected { background: color-mix(in srgb, currentColor 7%, transparent); }
    .fs h3 { font-size: .95rem; display: flex; gap: .5rem; align-items: baseline; }
    .activity { font-weight: 400; opacity: .6; font-size: .8rem; }
    .badge { margin-left: auto; font-size: .7rem; text-transform: uppercase;
             letter-spacing: .08em; opacity: .7; }
    .where { font: .75rem ui-monospace, monospace; opacity: .55; margin: .1rem 0 .4rem; }
    .stmt { font-family: ui-monospace, monospace; font-size: .82rem;
            padding: .15rem .4rem; border-radius: 3px; white-space: pre-wrap; }
    .stmt.unchanged { opacity: .45; }
    .stmt.added { background: color-mix(in srgb, var(--added) 18%, transparent); }
    .stmt.removed { background: color-mix(in srgb, var(--removed) 18%, transparent); }
    .stmt.modified del { display: block; text-decoration: none; opacity: .8;
                         background: color-mix(in srgb, var(--removed) 18%, transparent); }
    .stmt.modified ins { display: block; text-decoration: none;
                         background: color-mix(in srgb, var(--added) 18%, transparent); }
    .empty { opacity: .6; }
    @media (max-width: 60rem) { .panels { flex-direction: column; } }
    """

    /// Clicking a node in either panel selects it in both and
    /// scrolls its statement diff into view — the node-anchored
    /// half of the review story. Inline, tiny, no dependencies.
    private static let script = """
    function aroFocus(id) {
      var card = document.getElementById('node-' + id);
      document.querySelectorAll('.selected').forEach(function (el) {
        el.classList.remove('selected');
      });
      if (!card) { return; }
      card.classList.add('selected');
      document.querySelectorAll('g.node[data-node="' + id + '"]').forEach(function (g) {
        g.classList.add('selected');
      });
      card.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }
    """

    // MARK: - Text helpers

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Attribute values additionally need their quotes escaped —
    /// a feature-set name is arbitrary text and one stray `"` would
    /// otherwise break out of the attribute.
    static func attribute(_ text: String) -> String {
        escape(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// DOM id for a feature set. Non-alphanumerics collapse to `-`,
    /// which can collide in principle; a suffixing scheme would be
    /// noise for a report of a few dozen nodes and names that
    /// differ only in punctuation are already indistinguishable to
    /// a reader.
    static func slug(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    private static func int(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}
