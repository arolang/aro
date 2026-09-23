// ============================================================
// DeleteResultFieldsTests.swift
// ARO Runtime — what a Delete statement's result holds
// ARO-0007 §6.4, GitLab #866
// ============================================================
//
// `Delete the <gone> from the <orders-repository> where <id> is <id>.` bound
// `<gone>` to a value with nothing an ARO program could read: not how many
// rows went, not whether any did. A handler could not report "deleted 3", and
// a delete that matched nothing looked exactly like one that matched.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Delete result fields (#866)")
struct DeleteResultFieldsTests {

    private func context(_ storage: InMemoryRepositoryStorage) -> RuntimeContext {
        let container = RuntimeContainer(repositoryStorage: storage)
        return RuntimeContext(featureSetName: "Test", container: container)
    }

    private func delete(
        _ repository: String,
        from storage: InMemoryRepositoryStorage,
        where field: String? = nil,
        equals value: (any Sendable)? = nil,
        resultName: String = "gone"
    ) async throws -> [String: any Sendable] {
        let span = SourceSpan(at: SourceLocation())
        let ctx = context(storage)
        if let field, let value {
            ctx.bind("_where_field_", value: field)
            ctx.bind("_where_value_", value: value)
        }
        let result = try await DeleteAction().execute(
            result: ResultDescriptor(base: resultName, specifiers: [], span: span),
            object: ObjectDescriptor(preposition: .from, base: repository,
                                     specifiers: [], span: span),
            context: ctx)
        return try #require(result as? [String: any Sendable])
    }

    private func seeded(_ repository: String, rows: [[String: any Sendable]]) async -> InMemoryRepositoryStorage {
        let storage = InMemoryRepositoryStorage()
        for row in rows {
            await storage.store(value: row, in: repository, businessActivity: "seed")
        }
        return storage
    }

    // MARK: - count

    @Test("count says how many rows went")
    func countReportsRowsRemoved() async throws {
        let storage = await seeded("d1-repository", rows: [
            ["id": "1", "total": 10], ["id": "2", "total": 20], ["id": "3", "total": 10]
        ])
        let record = try await delete("d1-repository", from: storage,
                                      where: "total", equals: 10)
        #expect(record["count"] as? Int == 2)
        #expect(record["success"] as? Bool == true)
    }

    @Test("a delete that matched nothing is distinguishable from one that matched")
    func nonMatchingDeleteIsZero() async throws {
        // The whole point of the issue: both used to look identical.
        let storage = await seeded("d2-repository", rows: [["id": "1", "total": 10]])
        let record = try await delete("d2-repository", from: storage,
                                      where: "total", equals: 999)
        #expect(record["count"] as? Int == 0)
        #expect(record["success"] as? Bool == false)
    }

    // MARK: - deleted

    @Test("the removed rows come back")
    func deletedRowsAreReadable() async throws {
        let storage = await seeded("d3-repository", rows: [
            ["id": "1", "total": 10], ["id": "2", "total": 20]
        ])
        let record = try await delete("d3-repository", from: storage,
                                      where: "total", equals: 10)
        let rows = try #require(record["deleted"] as? [any Sendable])
        #expect(rows.count == 1)
        #expect((rows.first as? [String: any Sendable])?["id"] as? String == "1")
    }

    @Test("one match is still a list")
    func singleMatchIsStillAList() async throws {
        // A result whose shape depends on how many things it found would make
        // every reader of a delete handle two cases.
        let storage = await seeded("d4-repository", rows: [["id": "only", "total": 1]])
        let record = try await delete("d4-repository", from: storage,
                                      where: "total", equals: 1)
        #expect((record["deleted"] as? [any Sendable])?.count == 1)
    }

    @Test("no match is an empty list, not a missing field")
    func noMatchIsEmptyList() async throws {
        let storage = await seeded("d5-repository", rows: [["id": "1", "total": 10]])
        let record = try await delete("d5-repository", from: storage,
                                      where: "total", equals: 999)
        #expect((record["deleted"] as? [any Sendable])?.isEmpty == true)
    }

    // MARK: - Clearing a repository

    @Test("clearing reports how many entries the repository held")
    func clearReportsCount() async throws {
        // Counted before the clear — afterwards there is nothing to count, and
        // "cleared 0" would be indistinguishable from "cleared everything".
        let storage = await seeded("d6-repository", rows: [
            ["id": "1"], ["id": "2"], ["id": "3"]
        ])
        let record = try await delete("d6-repository", from: storage)
        #expect(record["count"] as? Int == 3)
        #expect(await storage.retrieve(from: "d6-repository", businessActivity: "t").isEmpty)
    }

    @Test("clearing an empty repository reports zero")
    func clearOfEmptyIsZero() async throws {
        let storage = InMemoryRepositoryStorage()
        let record = try await delete("d7-repository", from: storage)
        #expect(record["count"] as? Int == 0)
    }

    @Test("clearing does not read the rows back to report them")
    func clearDoesNotCarryRows() async throws {
        let storage = await seeded("d8-repository", rows: [["id": "1"], ["id": "2"]])
        let record = try await delete("d8-repository", from: storage)
        #expect((record["deleted"] as? [any Sendable])?.isEmpty == true)
    }

    // MARK: - The binding, not just the return value

    @Test("the statement's result name holds the record")
    func resultBindingIsTheRecord() async throws {
        // The rows used to be bound here and then overwritten by the returned
        // struct, which is why `<gone>` had nothing readable on it.
        let span = SourceSpan(at: SourceLocation())
        let storage = await seeded("d9-repository", rows: [["id": "1", "total": 10]])
        let ctx = context(storage)
        ctx.bind("_where_field_", value: "total")
        ctx.bind("_where_value_", value: 10)
        _ = try await DeleteAction().execute(
            result: ResultDescriptor(base: "gone", specifiers: [], span: span),
            object: ObjectDescriptor(preposition: .from, base: "d9-repository",
                                     specifiers: [], span: span),
            context: ctx)

        let bound = try #require(ctx.resolveAny("gone") as? [String: any Sendable])
        #expect(bound["count"] as? Int == 1)
    }

    // MARK: - The struct

    @Test("DeleteResult renders the fields a program reads")
    func structRendersDictionary() {
        let result = DeleteResult(target: "gone", success: true, count: 2,
                                  deleted: ["a", "b"])
        let dict = result.asDictionary
        #expect(dict["count"] as? Int == 2)
        #expect(dict["success"] as? Bool == true)
        #expect(dict["target"] as? String == "gone")
        #expect((dict["deleted"] as? [any Sendable])?.count == 2)
    }

    @Test("a DeleteResult built the old way still says nothing was removed")
    func defaultsAreHonest() {
        // The count/deleted arguments default, so a call site that has no rows
        // to report reports none rather than inventing one.
        let result = DeleteResult(target: "x", success: true)
        #expect(result.count == 0)
        #expect(result.deleted.isEmpty)
    }
}
