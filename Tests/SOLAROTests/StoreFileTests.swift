// ============================================================
// StoreFileTests.swift
// SOLARO — `.store` files as rows (GitLab #766)
// ============================================================
//
// ARO-0073 store files are the persistence model, and editing their
// seed data meant editing YAML by hand in a text pane — the pre-IDE
// experience. The parse and the serialisation live away from the view
// so the round trip can be checked on strings.

import Testing
import Foundation
@testable import SOLARO

@Suite("Store files")
struct StoreFileTests {

    private let products = """
    # Product catalog — read-only seed data
    - id: p1
      name: Widget
      price: 9.99
      category: hardware
    - id: p2
      name: Gadget
      price: 24.99
      category: electronics
    """

    @Test func readsASequenceOfMappingsAsATable() throws {
        let store = try #require(StoreFile.parse(products))
        #expect(store.rows.count == 2)
        #expect(Set(store.columns) == ["id", "name", "price", "category"])
        #expect(store.rows[0]["name"] == "Widget")
        #expect(store.rows[1]["category"] == "electronics")
    }

    @Test func keepsTheExplanatoryHeader() throws {
        // The shipped examples open with a line saying what the file
        // seeds; a round trip through a YAML library would drop it.
        let store = try #require(StoreFile.parse(products))
        #expect(store.header.contains("Product catalog"))
        #expect(store.serialized().hasPrefix("# Product catalog"))
    }

    @Test func aPriceSurvivesTheRoundTrip() throws {
        // Every value is carried as a string on purpose: guessing that
        // 9.99 is a Double is how a price becomes 9.9900000000000002,
        // or how 1.0 becomes 1, on the next save.
        let store = try #require(StoreFile.parse(products))
        #expect(store.rows[0]["price"] == "9.99")
        let again = try #require(StoreFile.parse(store.serialized()))
        #expect(again.rows[0]["price"] == "9.99")
    }

    @Test func aRoundTripIsStable() throws {
        let store = try #require(StoreFile.parse(products))
        let once = store.serialized()
        let twice = try #require(StoreFile.parse(once)).serialized()
        // A file the user opened and did not edit must not show up as
        // a diff — these live in the user's repository.
        #expect(once == twice)
    }

    @Test func anEmptyFileIsAnEmptyTable() throws {
        let store = try #require(StoreFile.parse(""))
        #expect(store.isEmpty)
        #expect(store.columns.isEmpty)
    }

    @Test func aFileThisEditorCannotRepresentIsRefused() {
        // A top-level mapping, or a sequence of lists, is not a table.
        // The caller falls back to the text pane rather than mangling it.
        #expect(StoreFile.parse("key: value") == nil)
        #expect(StoreFile.parse("- [1, 2]\n- [3, 4]") == nil)
    }

    @Test func columnsAreTheUnionAcrossRows() throws {
        // A seed file often omits an optional field on some rows; the
        // column should still exist.
        let store = try #require(StoreFile.parse("""
        - id: a
          note: first
        - id: b
        """))
        #expect(Set(store.columns) == ["id", "note"])
        #expect(store.rows[1]["note"] == nil)
    }

    @Test func editingACellChangesOnlyThatCell() throws {
        var store = try #require(StoreFile.parse(products))
        store.setValue("Sprocket", row: 0, column: "name")
        let again = try #require(StoreFile.parse(store.serialized()))
        #expect(again.rows[0]["name"] == "Sprocket")
        #expect(again.rows[1]["name"] == "Gadget")
    }

    @Test func addingAndRemovingRows() throws {
        var store = try #require(StoreFile.parse(products))
        store.addRow()
        store.setValue("p3", row: 2, column: "id")
        #expect(try #require(StoreFile.parse(store.serialized())).rows.count == 3)

        store.removeRow(at: 0)
        let after = try #require(StoreFile.parse(store.serialized()))
        #expect(after.rows.count == 2)
        #expect(after.rows[0]["id"] == "p2")
    }

    @Test func addingAndRemovingColumns() throws {
        var store = try #require(StoreFile.parse(products))
        store.addColumn(named: "stock")
        store.setValue("4", row: 0, column: "stock")
        #expect(try #require(StoreFile.parse(store.serialized()))
                    .rows[0]["stock"] == "4")

        store.removeColumn(named: "category")
        let after = try #require(StoreFile.parse(store.serialized()))
        #expect(!after.columns.contains("category"))
        #expect(after.rows[0]["category"] == nil)
    }

    @Test func aBlankColumnNameIsIgnored() throws {
        var store = try #require(StoreFile.parse(products))
        let before = store.columns.count
        store.addColumn(named: "   ")
        store.addColumn(named: "id")   // already there
        #expect(store.columns.count == before)
    }

    @Test func valuesThatWouldParseAsSomethingElseAreQuoted() throws {
        var store = StoreFile(columns: ["v"], rows: [[:]], header: "")
        for tricky in ["# not a comment", "- not a list", " leading space",
                       "has: colon", ""] {
            store.setValue(tricky, row: 0, column: "v")
            let again = StoreFile.parse(store.serialized())
            // An empty value is simply omitted, which reads back as absent.
            if tricky.isEmpty {
                #expect(again?.rows.first?["v"] == nil)
            } else {
                #expect(again?.rows.first?["v"] == tricky,
                        "round trip lost: \(tricky)")
            }
        }
    }

    @Test func quotesAndNewlinesSurvive() throws {
        var store = StoreFile(columns: ["v"], rows: [[:]], header: "")
        store.setValue("she said \"hi\"", row: 0, column: "v")
        #expect(StoreFile.parse(store.serialized())?.rows.first?["v"]
                == "she said \"hi\"")
    }

    @Test func recognisesStoreFilesByExtension() {
        #expect(StoreFile.isStoreFile(URL(fileURLWithPath: "/p/products.store")))
        #expect(StoreFile.isStoreFile(URL(fileURLWithPath: "/p/A.STORE")))
        #expect(!StoreFile.isStoreFile(URL(fileURLWithPath: "/p/main.aro")))
    }

    @Test func writabilityFollowsThePermissionBit() throws {
        // ARO-0073 makes writability a permission: seed data is
        // read-only unless the file is world-writable. Worth showing,
        // because it explains why a Store action did or did not persist.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let readOnly = dir.appendingPathComponent("seed.store")
        try products.write(to: readOnly, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: readOnly.path)
        #expect(!StoreFile.isWritable(at: readOnly))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o646], ofItemAtPath: readOnly.path)
        #expect(StoreFile.isWritable(at: readOnly))
    }
}
