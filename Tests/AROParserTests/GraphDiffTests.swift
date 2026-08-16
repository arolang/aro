// ============================================================
// GraphDiffTests.swift
// AROParser — feature-set / statement diff (GitLab #443)
// ============================================================

import Testing
@testable import AROParser

@Suite("Graph diff (#443)")
struct GraphDiffTests {

    private func parse(_ source: String) throws -> Program {
        try Parser.parse(source)
    }

    private func diff(_ before: String, _ after: String) throws -> AROGraphDiff {
        AROGraphDiff.compare(before: try parse(before), after: try parse(after))
    }

    private let base = """
    (listUsers: User API) {
        Retrieve the <users> from the <user-repository>.
        Return an <OK: status> with <users>.
    }
    """

    // MARK: - Feature-set level

    @Test("Identical programs report no change")
    func noChange() throws {
        let result = try diff(base, base)
        #expect(result.isEmpty)
        #expect(result.featureSets.count == 1)
        #expect(result.featureSets[0].change == .unchanged)
    }

    @Test("A new feature set is added")
    func addedFeatureSet() throws {
        let after = base + """

        (getUser: User API) {
            Extract the <id> from the <pathParameters: id>.
            Return an <OK: status> with <id>.
        }
        """
        let result = try diff(base, after)
        #expect(result.featureSets(.added).map(\.name) == ["getUser"])
        // Every statement inside an added set counts as added.
        #expect(result.featureSets(.added)[0].count(of: .added) == 2)
        #expect(result.featureSets(.unchanged).map(\.name) == ["listUsers"])
    }

    @Test("A deleted feature set is removed")
    func removedFeatureSet() throws {
        let before = base + """

        (deleteUser: User API) {
            Extract the <id> from the <pathParameters: id>.
            Return an <OK: status> with <id>.
        }
        """
        let result = try diff(before, base)
        #expect(result.featureSets(.removed).map(\.name) == ["deleteUser"])
        #expect(result.featureSets(.removed)[0].count(of: .removed) == 2)
    }

    @Test("Feature sets are matched by name, not position")
    func matchesByName() throws {
        let reordered = """
        (createUser: User API) {
            Extract the <data> from the <request: body>.
            Return a <Created: status> with <data>.
        }

        \(base)
        """
        let original = """
        \(base)

        (createUser: User API) {
            Extract the <data> from the <request: body>.
            Return a <Created: status> with <data>.
        }
        """
        // Moving a feature set within the file is not a change.
        let result = try diff(original, reordered)
        #expect(result.isEmpty)
    }

    @Test("A changed business activity marks the set modified")
    func businessActivityChange() throws {
        let after = """
        (listUsers: Admin API) {
            Retrieve the <users> from the <user-repository>.
            Return an <OK: status> with <users>.
        }
        """
        let result = try diff(base, after)
        #expect(result.featureSets[0].change == .modified)
    }

    // MARK: - Statement level

    @Test("An inserted statement is added, the rest stays put")
    func insertedStatement() throws {
        let after = """
        (listUsers: User API) {
            Retrieve the <users> from the <user-repository>.
            Log "listed" to the <console>.
            Return an <OK: status> with <users>.
        }
        """
        let result = try diff(base, after)
        let set = result.featureSets[0]
        #expect(set.change == .modified)
        #expect(set.count(of: .added) == 1)
        // The point of diffing the graph: the untouched statements
        // stay untouched even though one shifted down a line.
        #expect(set.count(of: .unchanged) == 2)
        #expect(set.count(of: .removed) == 0)
    }

    @Test("A deleted statement is removed")
    func deletedStatement() throws {
        let after = """
        (listUsers: User API) {
            Return an <OK: status> with <users>.
        }
        """
        let result = try diff(base, after)
        let set = result.featureSets[0]
        #expect(set.count(of: .removed) == 1)
        #expect(set.count(of: .unchanged) == 1)
    }

    @Test("An edited statement is one modified node, not a delete plus an add")
    func editedStatementCollapses() throws {
        // On a graph, remove-then-add would delete the node and draw
        // a new one — losing its position and any comment anchored
        // to it. Same verb, adjacent: it's the same node, edited.
        let after = """
        (listUsers: User API) {
            Retrieve the <users> from the <account-repository>.
            Return an <OK: status> with <users>.
        }
        """
        let result = try diff(base, after)
        let set = result.featureSets[0]
        #expect(set.count(of: .modified) == 1)
        #expect(set.count(of: .added) == 0)
        #expect(set.count(of: .removed) == 0)
        let edited = try #require(set.statements.first { $0.change == .modified })
        #expect(edited.before?.contains("user-repository") == true)
        #expect(edited.after?.contains("account-repository") == true)
        #expect(edited.verb.lowercased() == "retrieve")
    }

    @Test("A replaced statement with a different verb stays two entries")
    func differentVerbDoesNotCollapse() throws {
        let after = """
        (listUsers: User API) {
            Log "no repository" to the <console>.
            Return an <OK: status> with <users>.
        }
        """
        let result = try diff(base, after)
        let set = result.featureSets[0]
        #expect(set.count(of: .modified) == 0)
        #expect(set.count(of: .added) == 1)
        #expect(set.count(of: .removed) == 1)
    }

    @Test("Re-indentation is not a change")
    func whitespaceInsensitive() throws {
        let reindented = """
        (listUsers: User API) {
                Retrieve      the   <users>   from the <user-repository>.
            Return an <OK: status>     with <users>.
        }
        """
        #expect(try diff(base, reindented).isEmpty)
    }

    // MARK: - Whole-file cases

    @Test("A new file is entirely added")
    func newFile() throws {
        let result = AROGraphDiff.compare(before: nil, after: try parse(base))
        #expect(result.featureSets(.added).count == 1)
        #expect(result.statementCount(of: .added) == 2)
    }

    @Test("A deleted file is entirely removed")
    func deletedFile() throws {
        let result = AROGraphDiff.compare(before: try parse(base), after: nil)
        #expect(result.featureSets(.removed).count == 1)
        #expect(result.statementCount(of: .removed) == 2)
    }

    @Test("Two empty sides are an empty diff")
    func bothNil() {
        let result = AROGraphDiff.compare(before: nil, after: nil)
        #expect(result.featureSets.isEmpty)
        #expect(result.isEmpty)
    }

    // MARK: - Summary

    @Test("Summary counts statements across every feature set")
    func summaryCounts() throws {
        let after = """
        (listUsers: User API) {
            Retrieve the <users> from the <account-repository>.
            Log "listed" to the <console>.
            Return an <OK: status> with <users>.
        }

        (getUser: User API) {
            Extract the <id> from the <pathParameters: id>.
            Return an <OK: status> with <id>.
        }
        """
        let result = try diff(base, after)
        #expect(result.statementCount(of: .added) == 3)     // 1 log + 2 new set
        #expect(result.statementCount(of: .modified) == 1)
        #expect(!result.isEmpty)
        #expect(result.summaryLine.contains("2 feature sets touched"))
    }

    @Test("An unchanged program summarises as untouched")
    func summaryUnchanged() throws {
        let result = try diff(base, base)
        #expect(result.summaryLine.contains("0 feature sets touched"))
        #expect(result.summaryLine.contains("+0 −0 ~0"))
    }
}
