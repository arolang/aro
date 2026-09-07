// ============================================================
// GraphDiffReportTests.swift
// ARO CLI — `aro diff --graph --html` (GitLab #443)
// ============================================================
//
// The report is what a merge request links to, so the properties
// that matter are structural: two panels, every node drawn on both
// sides (a ghost where it doesn't exist), wires classified, and
// nothing fetched from the network.

import Testing
import AROParser
@testable import AROCLI

@Suite("Graph diff HTML report (#443)")
struct GraphDiffReportTests {

    private let before = """
    (createUser: User API) {
        Extract the <data> from the <request: body>.
        Emit a <UserCreated: event> with <data>.
        Return a <Created: status> with <data>.
    }

    (listUsers: User API) {
        Retrieve the <users> from the <user-repository>.
        Return an <OK: status> with <users>.
    }

    (Send Welcome Email: UserCreated Handler) {
        Log "welcome" to the <console>.
    }

    (health: Ops API) {
        Return an <OK: status> with <ping>.
    }
    """

    private let after = """
    (createUser: User API) {
        Extract the <data> from the <request: body>.
        Return an <OK: status> with <data>.
    }

    (Send Welcome Email: UserCreated Handler) {
        Log "welcome" to the <console>.
    }

    (health: Ops API) {
        Return an <OK: status> with <ping>.
    }
    """

    private func report(includeUnchanged: Bool = false) throws -> String {
        let diff = FeatureGraphDiff.compare(
            before: FeatureGraph.build(files: ["app.aro": DiffCommand.file(before)]),
            after: FeatureGraph.build(files: ["app.aro": DiffCommand.file(after)]),
            beforeLabel: "main",
            afterLabel: "my-branch")
        return GraphDiffHTMLReport.render(
            range: "main..my-branch", diff: diff, includeUnchanged: includeUnchanged)
    }

    @Test("The report is one self-contained document")
    func selfContained() throws {
        let html = try report()
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.hasSuffix("</html>"))
        // No stylesheet, script, image or font fetched: a CI
        // artifact opened from a file:// URL has to render with no
        // network at all.
        #expect(!html.contains("<link"))
        #expect(!html.contains("src="))
        #expect(!html.contains("@import"))
        #expect(!html.contains("http://"))
        #expect(!html.contains("https://"))
    }

    @Test("Both revisions are drawn, side by side")
    func twoPanels() throws {
        let html = try report()
        #expect(html.contains("data-side=\"before\""))
        #expect(html.contains("data-side=\"after\""))
        #expect(count(of: "<svg", in: html) == 2)
        #expect(html.contains("<h2>main</h2>"))
        #expect(html.contains("<h2>my-branch</h2>"))
    }

    @Test("Nodes are bordered by what happened to them")
    func nodeClasses() throws {
        let html = try report()
        #expect(html.contains("<g class=\"node modified\" data-node=\"app-aro-createUser\""))
        #expect(html.contains("<g class=\"node removed\" data-node=\"app-aro-listUsers\""))
    }

    @Test("A node missing from one side is a ghost, not a gap")
    func ghostNode() throws {
        let html = try report()
        // `listUsers` exists only on the left, so the right panel
        // draws it dashed — that keeps the two layouts aligned
        // exactly where the change is.
        #expect(html.contains("<g class=\"node ghost\" data-node=\"app-aro-listUsers\""))
        #expect(count(of: "data-node=\"app-aro-listUsers\"", in: html) == 2)
    }

    @Test("A wire that vanished is drawn and listed")
    func wireDiff() throws {
        let html = try report()
        #expect(html.contains("<path class=\"wire removed\""))
        #expect(html.contains("Wires that moved"))
        #expect(html.contains("──event(UserCreated)──▶"))
    }

    @Test("Every rendered node gets a statement-diff card to click through to")
    func detailCards() throws {
        let html = try report()
        #expect(html.contains("id=\"node-app-aro-createUser\""))
        #expect(html.contains("id=\"node-app-aro-listUsers\""))
        #expect(html.contains("onclick=\"aroFocus('app-aro-createUser')\""))
        // Statements read as source, not as the AST's debug form.
        #expect(html.contains("Return a &lt;Created: status&gt; with &lt;data&gt;."))
    }

    @Test("Untouched feature sets stay out unless asked for")
    func unchangedHidden() throws {
        // `Send Welcome Email` is untouched, but the wire that
        // vanished lands on it, so it is shown either way — that
        // wire *is* the change. `health` is untouched and wired to
        // nothing, so it only appears with `--all`.
        let quiet = try report()
        #expect(quiet.contains("data-node=\"app-aro-Send-Welcome-Email\""))
        #expect(!quiet.contains("data-node=\"app-aro-health\""))
        let verbose = try report(includeUnchanged: true)
        #expect(verbose.contains("data-node=\"app-aro-health\""))
    }

    @Test("Markup in a feature-set name cannot escape its attribute")
    func escaping() {
        #expect(GraphDiffHTMLReport.escape("<a> & </a>") == "&lt;a&gt; &amp; &lt;/a&gt;")
        #expect(GraphDiffHTMLReport.attribute("say \"hi\"") == "say &quot;hi&quot;")
        #expect(GraphDiffHTMLReport.slug("Send Welcome Email") == "Send-Welcome-Email")
    }

    @Test("An empty comparison says so instead of drawing nothing")
    func emptyReport() {
        let html = GraphDiffHTMLReport.render(
            range: "main..main",
            diff: FeatureGraphDiff(nodes: [], edges: []))
        #expect(html.contains("No feature-set changes."))
        #expect(!html.contains("<svg"))
    }

    // MARK: - Range parsing

    @Test("A range splits into two revisions; a bare one means the working tree")
    func ranges() throws {
        let pair = try DiffCommand.parseRange("main..my-branch")
        #expect(pair.0 == "main")
        #expect(pair.1 == "my-branch")
        let single = try DiffCommand.parseRange("main")
        #expect(single.0 == "main")
        #expect(single.1 == nil)
    }

    @Test("A symmetric range is refused rather than silently reinterpreted")
    func symmetricRangeRejected() {
        #expect(throws: (any Error).self) {
            _ = try DiffCommand.parseRange("main...my-branch")
        }
    }

    private func count(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
