// StreamingTests.swift
// Tests for ARO Streaming Execution Engine

import Testing
import Foundation
@testable import ARORuntime

// MARK: - AROStream Tests

@Suite("AROStream Tests")
struct AROStreamTests {

    // MARK: - Factory Methods

    @Test("Creates stream from array")
    func testFromArray() async throws {
        let array = [1, 2, 3, 4, 5]
        let stream = AROStream.from(array)
        let result = try await stream.collect()
        #expect(result == [1, 2, 3, 4, 5])
    }

    @Test("Creates empty stream")
    func testEmpty() async throws {
        let stream: AROStream<Int> = .empty
        let result = try await stream.collect()
        #expect(result.isEmpty)
    }

    @Test("Creates stream from single element")
    func testJust() async throws {
        let stream = AROStream.just(42)
        let result = try await stream.collect()
        #expect(result == [42])
    }

    // MARK: - Transformations

    @Test("Filter elements")
    func testFilter() async throws {
        let stream = AROStream.from([1, 2, 3, 4, 5, 6])
            .filter { $0 % 2 == 0 }
        let result = try await stream.collect()
        #expect(result == [2, 4, 6])
    }

    @Test("Map elements")
    func testMap() async throws {
        let stream = AROStream.from([1, 2, 3])
            .map { $0 * 2 }
        let result = try await stream.collect()
        #expect(result == [2, 4, 6])
    }

    @Test("FlatMap elements")
    func testFlatMap() async throws {
        let stream = AROStream.from([1, 2, 3])
            .flatMap { [$0, $0 * 10] }
        let result = try await stream.collect()
        #expect(result == [1, 10, 2, 20, 3, 30])
    }

    @Test("CompactMap filters nils")
    func testCompactMap() async throws {
        let stream = AROStream.from(["1", "two", "3", "four"])
            .compactMap { Int($0) }
        let result = try await stream.collect()
        #expect(result == [1, 3])
    }

    @Test("Take first n elements")
    func testTake() async throws {
        let stream = AROStream.from([1, 2, 3, 4, 5])
            .take(3)
        let result = try await stream.collect()
        #expect(result == [1, 2, 3])
    }

    @Test("Drop first n elements")
    func testDrop() async throws {
        let stream = AROStream.from([1, 2, 3, 4, 5])
            .drop(2)
        let result = try await stream.collect()
        #expect(result == [3, 4, 5])
    }

    @Test("TakeWhile takes until predicate fails")
    func testTakeWhile() async throws {
        let stream = AROStream.from([1, 2, 3, 4, 5, 1, 2])
            .takeWhile { $0 < 4 }
        let result = try await stream.collect()
        #expect(result == [1, 2, 3])
    }

    @Test("DropWhile skips until predicate fails")
    func testDropWhile() async throws {
        let stream = AROStream.from([1, 2, 3, 4, 2, 1])
            .dropWhile { $0 < 3 }
        let result = try await stream.collect()
        #expect(result == [3, 4, 2, 1])
    }

    // MARK: - Actions

    @Test("Reduce stream")
    func testReduce() async throws {
        let sum = try await AROStream.from([1, 2, 3, 4, 5])
            .reduce(0) { $0 + $1 }
        #expect(sum == 15)
    }

    @Test("Count elements")
    func testCount() async throws {
        let count = try await AROStream.from([1, 2, 3, 4, 5])
            .count()
        #expect(count == 5)
    }

    @Test("First element")
    func testFirst() async throws {
        let first = try await AROStream.from([1, 2, 3])
            .first()
        #expect(first == 1)
    }

    @Test("First with predicate")
    func testFirstWhere() async throws {
        let first = try await AROStream.from([1, 2, 3, 4, 5])
            .first { $0 > 3 }
        #expect(first == 4)
    }

    @Test("Contains element")
    func testContains() async throws {
        let contains = try await AROStream.from([1, 2, 3])
            .contains { $0 == 2 }
        #expect(contains == true)

        let notContains = try await AROStream.from([1, 2, 3])
            .contains { $0 == 5 }
        #expect(notContains == false)
    }

    @Test("AllSatisfy predicate")
    func testAllSatisfy() async throws {
        let allPositive = try await AROStream.from([1, 2, 3])
            .allSatisfy { $0 > 0 }
        #expect(allPositive == true)

        let allEven = try await AROStream.from([1, 2, 3])
            .allSatisfy { $0 % 2 == 0 }
        #expect(allEven == false)
    }

    // MARK: - Numeric Extensions

    @Test("Sum numeric stream")
    func testSum() async throws {
        let sum = try await AROStream.from([1, 2, 3, 4, 5]).sum()
        #expect(sum == 15)
    }

    @Test("Min element")
    func testMin() async throws {
        let min = try await AROStream.from([3, 1, 4, 1, 5]).min()
        #expect(min == 1)
    }

    @Test("Max element")
    func testMax() async throws {
        let max = try await AROStream.from([3, 1, 4, 1, 5]).max()
        #expect(max == 5)
    }

    // MARK: - Dictionary Streams

    @Test("WhereField equals")
    func testWhereFieldEquals() async throws {
        let rows: [[String: any Sendable]] = [
            ["name": "Alice", "status": "active"],
            ["name": "Bob", "status": "inactive"],
            ["name": "Charlie", "status": "active"]
        ]

        let active = try await AROStream.from(rows)
            .whereField("status", equals: "active")
            .collect()

        #expect(active.count == 2)
        #expect(active[0]["name"] as? String == "Alice")
        #expect(active[1]["name"] as? String == "Charlie")
    }

    @Test("Project fields")
    func testProject() async throws {
        let rows: [[String: any Sendable]] = [
            ["name": "Alice", "age": 30, "city": "NYC"],
            ["name": "Bob", "age": 25, "city": "LA"]
        ]

        let projected = try await AROStream.from(rows)
            .project(["name", "age"])
            .collect()

        #expect(projected[0].count == 2)
        #expect(projected[0]["city"] == nil)
    }

    @Test("Extract field as stream")
    func testFieldExtraction() async throws {
        let rows: [[String: any Sendable]] = [
            ["name": "Alice", "age": 30],
            ["name": "Bob", "age": 25],
            ["name": "Charlie", "age": 35]
        ]

        let names = try await AROStream.from(rows)
            .field("name", as: String.self)
            .collect()

        #expect(names == ["Alice", "Bob", "Charlie"])
    }

    // MARK: - Pipeline Composition

    @Test("Chain multiple transformations")
    func testPipelineChaining() async throws {
        let result = try await AROStream.from([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
            .filter { $0 % 2 == 0 }  // [2, 4, 6, 8, 10]
            .map { $0 * 2 }          // [4, 8, 12, 16, 20]
            .take(3)                  // [4, 8, 12]
            .reduce(0) { $0 + $1 }    // 24

        #expect(result == 24)
    }

    @Test("Pipeline composition maintains order")
    func testPipelineOrder() async throws {
        let result = try await AROStream.from([1, 2, 3])
            .map { $0 * 10 }
            .filter { $0 > 15 }
            .map { $0 + 1 }
            .collect()

        #expect(result == [21, 31])
    }
}

// MARK: - StreamTee Tests

@Suite("StreamTee Tests")
struct StreamTeeTests {

    @Test("Create multiple consumers from single source")
    func testMultipleConsumers() async throws {
        let source = AROStream.from([1, 2, 3, 4, 5])
        let streams = await source.tee(consumers: 2)

        #expect(streams.count == 2)

        // Both consumers should get all elements
        let result1 = try await streams[0].collect()
        let result2 = try await streams[1].collect()

        #expect(result1 == [1, 2, 3, 4, 5])
        #expect(result2 == [1, 2, 3, 4, 5])
    }

    @Test("Stream tee with three consumers")
    func testThreeConsumers() async throws {
        let source = AROStream.from([10, 20, 30])
        let streams = await source.tee(consumers: 3)

        let result1 = try await streams[0].collect()
        let result2 = try await streams[1].collect()
        let result3 = try await streams[2].collect()

        #expect(result1 == [10, 20, 30])
        #expect(result2 == [10, 20, 30])
        #expect(result3 == [10, 20, 30])
    }
}

// MARK: - CSVStreamParser Tests

@Suite("CSVStreamParser Tests")
struct CSVStreamParserTests {

    @Test("Parse simple CSV")
    func testParseSimpleCSV() async throws {
        let csv = """
        name,age,city
        Alice,30,NYC
        Bob,25,LA
        Charlie,35,Chicago
        """

        let result = try await AROStream<[String: any Sendable]>
            .fromCSVString(csv)
            .collect()

        #expect(result.count == 3)
        #expect(result[0]["name"] as? String == "Alice")
        #expect(result[0]["age"] as? Int == 30)
        #expect(result[1]["city"] as? String == "LA")
    }

    @Test("Parse CSV with quoted fields")
    func testQuotedFields() async throws {
        let csv = """
        name,description
        Alice,"Software Engineer"
        Bob,"Senior Developer, Team Lead"
        """

        let result = try await AROStream<[String: any Sendable]>
            .fromCSVString(csv)
            .collect()

        #expect(result.count == 2)
        #expect(result[0]["description"] as? String == "Software Engineer")
        #expect(result[1]["description"] as? String == "Senior Developer, Team Lead")
    }

    @Test("Parse CSV with escaped quotes")
    func testEscapedQuotes() async throws {
        let csv = "name,quote\nAlice,\"She said \"\"hello\"\"\""

        let result = try await AROStream<[String: any Sendable]>
            .fromCSVString(csv)
            .collect()

        #expect(result.count == 1)
        #expect(result[0]["quote"] as? String == "She said \"hello\"")
    }

    @Test("Parse TSV data")
    func testTSV() async throws {
        let tsv = "name\tage\nAlice\t30"

        var parser = CSVStreamParser(config: .tsv)
        let rows = parser.feed(tsv + "\n")

        #expect(rows.count == 1)
    }

    @Test("Normalize header names")
    func testHeaderNormalization() async throws {
        let csv = "First Name,Last.Name,Email Address\nAlice,Smith,alice@example.com"

        let result = try await AROStream<[String: any Sendable]>
            .fromCSVString(csv)
            .collect()

        #expect(result.count == 1)
        // Headers should be normalized: "First Name" -> "first-name"
        #expect(result[0]["first-name"] as? String == "Alice")
        #expect(result[0]["last-name"] as? String == "Smith")
        #expect(result[0]["email-address"] as? String == "alice@example.com")
    }

    @Test("Parse CSV from file")
    func testFromFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-\(UUID()).csv")

        let csv = """
        id,name,score
        1,Alice,95
        2,Bob,87
        """

        try csv.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let result = try await AROStream<[String: any Sendable]>
            .fromCSV(path: testFile.path)
            .collect()

        #expect(result.count == 2)
        #expect(result[0]["id"] as? Int == 1)
        #expect(result[1]["score"] as? Int == 87)
    }

    @Test("Parse boolean values")
    func testBooleanParsing() async throws {
        let csv = """
        name,active,verified
        Alice,true,yes
        Bob,false,no
        """

        let result = try await AROStream<[String: any Sendable]>
            .fromCSVString(csv)
            .collect()

        #expect(result.count == 2)
        #expect(result[0]["active"] as? Bool == true)
        #expect(result[0]["verified"] as? Bool == true)
        #expect(result[1]["active"] as? Bool == false)
        #expect(result[1]["verified"] as? Bool == false)
    }
}

// MARK: - RingBuffer Tests

@Suite("RingBuffer Tests")
struct RingBufferTests {

    @Test("Append and retrieve elements")
    func testAppendAndRetrieve() async {
        let buffer = RingBuffer<Int>(capacity: 5)

        await buffer.append(1)
        await buffer.append(2)
        await buffer.append(3)

        let count = await buffer.count
        #expect(count == 3)

        let elem0 = await buffer.element(at: 0)
        let elem1 = await buffer.element(at: 1)
        let elem2 = await buffer.element(at: 2)

        #expect(elem0 == 1)
        #expect(elem1 == 2)
        #expect(elem2 == 3)
    }

    @Test("Wrap around when capacity exceeded")
    func testWrapAround() async {
        let buffer = RingBuffer<Int>(capacity: 3)

        await buffer.append(1)
        await buffer.append(2)
        await buffer.append(3)
        await buffer.append(4) // This should evict 1

        let count = await buffer.count
        #expect(count == 3)

        // Element at index 0 was evicted
        let wasEvicted = await buffer.wasEvicted(at: 0)
        #expect(wasEvicted == true)

        // Elements 1, 2, 3 should still be accessible
        let elem1 = await buffer.element(at: 1)
        let elem2 = await buffer.element(at: 2)
        let elem3 = await buffer.element(at: 3)

        #expect(elem1 == 2)
        #expect(elem2 == 3)
        #expect(elem3 == 4)
    }

    @Test("Trim removes old elements")
    func testTrim() async {
        let buffer = RingBuffer<Int>(capacity: 10)

        await buffer.append(1)
        await buffer.append(2)
        await buffer.append(3)
        await buffer.append(4)
        await buffer.append(5)

        // Trim everything before index 3
        await buffer.trimTo(minimumIndex: 3)

        // Elements 0, 1, 2 should be evicted
        let evicted0 = await buffer.wasEvicted(at: 0)
        let evicted1 = await buffer.wasEvicted(at: 1)
        let evicted2 = await buffer.wasEvicted(at: 2)

        #expect(evicted0 == true)
        #expect(evicted1 == true)
        #expect(evicted2 == true)

        // Elements 3, 4 should still be accessible
        let elem3 = await buffer.element(at: 3)
        let elem4 = await buffer.element(at: 4)

        #expect(elem3 == 4)
        #expect(elem4 == 5)
    }

    @Test("IsAvailable checks element existence")
    func testIsAvailable() async {
        let buffer = RingBuffer<Int>(capacity: 5)

        await buffer.append(1)
        await buffer.append(2)

        let available0 = await buffer.isAvailable(at: 0)
        let available1 = await buffer.isAvailable(at: 1)
        let available5 = await buffer.isAvailable(at: 5) // Not yet written

        #expect(available0 == true)
        #expect(available1 == true)
        #expect(available5 == false)
    }

    @Test("Default capacity is 4096")
    func testDefaultCapacity() {
        let capacity = RingBuffer<Int>.defaultCapacity
        #expect(capacity == 4096)
    }
}

// MARK: - JSONStreamParser Tests

@Suite("JSONStreamParser Tests")
struct JSONStreamParserTests {

    @Test("Parse JSONL file")
    func testParseJSONL() async throws {
        // Create temporary JSONL file
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-\(UUID()).jsonl")

        let jsonl = """
        {"name": "Alice", "age": 30}
        {"name": "Bob", "age": 25}
        {"name": "Charlie", "age": 35}
        """

        try jsonl.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let stream = JSONStreamParser.stream(path: testFile.path)
        let result = try await stream.collect()

        #expect(result.count == 3)
        #expect(result[0]["name"] as? String == "Alice")
        #expect(result[1]["name"] as? String == "Bob")
        #expect(result[2]["name"] as? String == "Charlie")
    }

    @Test("Skip empty lines in JSONL")
    func testSkipEmptyLines() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-\(UUID()).jsonl")

        let jsonl = """
        {"name": "Alice"}

        {"name": "Bob"}

        """

        try jsonl.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let stream = JSONStreamParser.stream(path: testFile.path)
        let result = try await stream.collect()

        #expect(result.count == 2)
    }

    @Test("Skip comments in JSONL")
    func testSkipComments() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-\(UUID()).jsonl")

        let jsonl = """
        # This is a comment
        {"name": "Alice"}
        // Another comment
        {"name": "Bob"}
        """

        try jsonl.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let stream = JSONStreamParser.stream(path: testFile.path)
        let result = try await stream.collect()

        #expect(result.count == 2)
    }

    @Test("Skip malformed lines in JSONL")
    func testSkipMalformed() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-\(UUID()).jsonl")

        let jsonl = """
        {"name": "Alice"}
        {this is not valid json
        {"name": "Bob"}
        """

        try jsonl.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let stream = JSONStreamParser.stream(path: testFile.path, config: .jsonl)
        let result = try await stream.collect()

        #expect(result.count == 2)
        #expect(result[0]["name"] as? String == "Alice")
        #expect(result[1]["name"] as? String == "Bob")
    }

    @Test("Parse JSON array file")
    func testParseJSONArray() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-\(UUID()).json")

        let json = """
        [
            {"name": "Alice", "age": 30},
            {"name": "Bob", "age": 25},
            {"name": "Charlie", "age": 35}
        ]
        """

        try json.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let stream = JSONStreamParser.stream(path: testFile.path)
        let result = try await stream.collect()

        #expect(result.count == 3)
        #expect(result[0]["name"] as? String == "Alice")
    }

    @Test("Auto-detect format from file extension")
    func testAutoDetectFormat() async throws {
        let tempDir = FileManager.default.temporaryDirectory

        // JSONL file
        let jsonlFile = tempDir.appendingPathComponent("test-\(UUID()).jsonl")
        try "{\"type\": \"jsonl\"}".write(to: jsonlFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: jsonlFile) }

        // JSON file with array
        let jsonFile = tempDir.appendingPathComponent("test-\(UUID()).json")
        try "[{\"type\": \"json\"}]".write(to: jsonFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: jsonFile) }

        let jsonlResult = try await JSONStreamParser.stream(path: jsonlFile.path).collect()
        let jsonResult = try await JSONStreamParser.stream(path: jsonFile.path).collect()

        #expect(jsonlResult[0]["type"] as? String == "jsonl")
        #expect(jsonResult[0]["type"] as? String == "json")
    }

    @Test("Handle nested objects")
    func testNestedObjects() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-\(UUID()).jsonl")

        let jsonl = """
        {"name": "Alice", "address": {"city": "NYC", "zip": "10001"}}
        """

        try jsonl.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let stream = JSONStreamParser.stream(path: testFile.path)
        let result = try await stream.collect()

        #expect(result.count == 1)

        let address = result[0]["address"] as? [String: any Sendable]
        #expect(address?["city"] as? String == "NYC")
    }

    @Test("Handle arrays in objects")
    func testArraysInObjects() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-\(UUID()).jsonl")

        let jsonl = """
        {"name": "Alice", "tags": ["admin", "user"]}
        """

        try jsonl.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let stream = JSONStreamParser.stream(path: testFile.path)
        let result = try await stream.collect()

        #expect(result.count == 1)

        let tags = result[0]["tags"] as? [any Sendable]
        #expect(tags?.count == 2)
    }

    @Test("Convert numeric types correctly")
    func testNumericConversion() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-\(UUID()).jsonl")

        let jsonl = """
        {"integer": 42, "float": 3.14, "boolean": true}
        """

        try jsonl.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let stream = JSONStreamParser.stream(path: testFile.path)
        let result = try await stream.collect()

        #expect(result.count == 1)
        #expect(result[0]["integer"] as? Int == 42)
        #expect(result[0]["float"] as? Double == 3.14)
        #expect(result[0]["boolean"] as? Bool == true)
    }

    @Test("Use fromJSONL convenience method")
    func testFromJSONLConvenience() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-\(UUID()).jsonl")

        try "{\"id\": 1}".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let result = try await AROStream<[String: any Sendable]>
            .fromJSONL(path: testFile.path)
            .collect()

        #expect(result.count == 1)
        #expect(result[0]["id"] as? Int == 1)
    }
}
