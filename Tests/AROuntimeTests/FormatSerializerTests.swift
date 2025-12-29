import XCTest
@testable import ARORuntime

/// Tests for ARO-0040: Format-Aware File I/O
final class FormatSerializerTests: XCTestCase {

    // MARK: - FileFormat Detection Tests

    func testDetectJSON() {
        XCTAssertEqual(FileFormat.detect(from: "data.json"), .json)
        XCTAssertEqual(FileFormat.detect(from: "/path/to/file.JSON"), .json)
    }

    func testDetectYAML() {
        XCTAssertEqual(FileFormat.detect(from: "config.yaml"), .yaml)
        XCTAssertEqual(FileFormat.detect(from: "config.yml"), .yaml)
    }

    func testDetectXML() {
        XCTAssertEqual(FileFormat.detect(from: "data.xml"), .xml)
    }

    func testDetectTOML() {
        XCTAssertEqual(FileFormat.detect(from: "config.toml"), .toml)
    }

    func testDetectCSV() {
        XCTAssertEqual(FileFormat.detect(from: "data.csv"), .csv)
    }

    func testDetectTSV() {
        XCTAssertEqual(FileFormat.detect(from: "data.tsv"), .tsv)
    }

    func testDetectMarkdown() {
        XCTAssertEqual(FileFormat.detect(from: "report.md"), .markdown)
    }

    func testDetectHTML() {
        XCTAssertEqual(FileFormat.detect(from: "page.html"), .html)
        XCTAssertEqual(FileFormat.detect(from: "page.htm"), .html)
    }

    func testDetectText() {
        XCTAssertEqual(FileFormat.detect(from: "config.txt"), .text)
    }

    func testDetectSQL() {
        XCTAssertEqual(FileFormat.detect(from: "backup.sql"), .sql)
    }

    func testDetectBinary() {
        XCTAssertEqual(FileFormat.detect(from: "data.obj"), .binary)
        XCTAssertEqual(FileFormat.detect(from: "data.bin"), .binary)
    }

    func testUnknownExtensionDefaultsToBinary() {
        XCTAssertEqual(FileFormat.detect(from: "data.xyz"), .binary)
        XCTAssertEqual(FileFormat.detect(from: "noextension"), .binary)
    }

    // MARK: - JSON Serialization Tests

    func testSerializeJSONObject() {
        let data: [String: any Sendable] = ["id": 1, "name": "Alice"]
        let json = FormatSerializer.serialize(data, format: .json, variableName: "user")

        XCTAssertTrue(json.contains("\"id\""))
        XCTAssertTrue(json.contains("\"name\""))
        XCTAssertTrue(json.contains("\"Alice\""))
    }

    func testSerializeJSONArray() {
        let data: [any Sendable] = [
            ["id": 1, "name": "Alice"] as [String: any Sendable],
            ["id": 2, "name": "Bob"] as [String: any Sendable]
        ]
        let json = FormatSerializer.serialize(data, format: .json, variableName: "users")

        XCTAssertTrue(json.hasPrefix("["))
        XCTAssertTrue(json.contains("Alice"))
        XCTAssertTrue(json.contains("Bob"))
    }

    // MARK: - YAML Serialization Tests

    func testSerializeYAMLObject() {
        let data: [String: any Sendable] = ["id": 1, "name": "Alice"]
        let yaml = FormatSerializer.serialize(data, format: .yaml, variableName: "user")

        XCTAssertTrue(yaml.contains("id: 1"))
        XCTAssertTrue(yaml.contains("name: Alice"))
    }

    func testSerializeYAMLArray() {
        let data: [any Sendable] = [
            ["id": 1, "name": "Alice"] as [String: any Sendable],
            ["id": 2, "name": "Bob"] as [String: any Sendable]
        ]
        let yaml = FormatSerializer.serialize(data, format: .yaml, variableName: "users")

        // YAML array items start with "- "
        XCTAssertTrue(yaml.contains("- "))
        XCTAssertTrue(yaml.contains("id"))
        XCTAssertTrue(yaml.contains("Alice"))
    }

    // MARK: - CSV Serialization Tests

    func testSerializeCSVArray() {
        let data: [any Sendable] = [
            ["id": 1, "name": "Alice"] as [String: any Sendable],
            ["id": 2, "name": "Bob"] as [String: any Sendable]
        ]
        let csv = FormatSerializer.serialize(data, format: .csv, variableName: "users")

        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 3) // header + 2 rows
        XCTAssertTrue(lines[0].contains("id"))
        XCTAssertTrue(lines[0].contains("name"))
    }

    func testSerializeCSVSingleObject() {
        let data: [String: any Sendable] = ["id": 1, "name": "Alice"]
        let csv = FormatSerializer.serialize(data, format: .csv, variableName: "user")

        XCTAssertTrue(csv.contains("key,value"))
        XCTAssertTrue(csv.contains("id,1"))
        XCTAssertTrue(csv.contains("name,Alice"))
    }

    // MARK: - Markdown Serialization Tests

    func testSerializeMarkdownTable() {
        let data: [any Sendable] = [
            ["id": 1, "name": "Alice"] as [String: any Sendable],
            ["id": 2, "name": "Bob"] as [String: any Sendable]
        ]
        let md = FormatSerializer.serialize(data, format: .markdown, variableName: "users")

        XCTAssertTrue(md.contains("| id | name |"))
        XCTAssertTrue(md.contains("|---|"))
        XCTAssertTrue(md.contains("| 1 | Alice |"))
    }

    // MARK: - SQL Serialization Tests

    func testSerializeSQLInsert() {
        let data: [any Sendable] = [
            ["id": 1, "name": "Alice"] as [String: any Sendable],
            ["id": 2, "name": "Bob"] as [String: any Sendable]
        ]
        let sql = FormatSerializer.serialize(data, format: .sql, variableName: "users")

        XCTAssertTrue(sql.contains("INSERT INTO users"))
        XCTAssertTrue(sql.contains("VALUES (1, 'Alice')"))
        XCTAssertTrue(sql.contains("VALUES (2, 'Bob')"))
    }

    // MARK: - XML Serialization Tests

    func testSerializeXML() {
        let data: [String: any Sendable] = ["id": 1, "name": "Alice"]
        let xml = FormatSerializer.serialize(data, format: .xml, variableName: "user")

        XCTAssertTrue(xml.contains("<?xml version="))
        XCTAssertTrue(xml.contains("<user>"))
        XCTAssertTrue(xml.contains("<id>1</id>"))
        XCTAssertTrue(xml.contains("<name>Alice</name>"))
        XCTAssertTrue(xml.contains("</user>"))
    }

    // MARK: - TOML Serialization Tests

    func testSerializeTOML() {
        let data: [String: any Sendable] = ["id": 1, "name": "Alice"]
        let toml = FormatSerializer.serialize(data, format: .toml, variableName: "user")

        XCTAssertTrue(toml.contains("id = 1"))
        XCTAssertTrue(toml.contains("name = \"Alice\""))
    }

    // MARK: - Text Serialization Tests

    func testSerializeText() {
        let data: [String: any Sendable] = ["id": 1, "name": "Alice"]
        let text = FormatSerializer.serialize(data, format: .text, variableName: "user")

        XCTAssertTrue(text.contains("id=1"))
        XCTAssertTrue(text.contains("name=Alice"))
    }
}

// MARK: - Format Deserializer Tests

final class FormatDeserializerTests: XCTestCase {

    // MARK: - JSON Deserialization Tests

    func testDeserializeJSONObject() {
        let json = """
        {"id": 1, "name": "Alice"}
        """
        let result = FormatDeserializer.deserialize(json, format: .json)

        guard let dict = result as? [String: any Sendable] else {
            XCTFail("Expected dictionary")
            return
        }
        XCTAssertEqual(dict["id"] as? Int, 1)
        XCTAssertEqual(dict["name"] as? String, "Alice")
    }

    func testDeserializeJSONArray() {
        let json = """
        [{"id": 1}, {"id": 2}]
        """
        let result = FormatDeserializer.deserialize(json, format: .json)

        guard let array = result as? [any Sendable] else {
            XCTFail("Expected array")
            return
        }
        XCTAssertEqual(array.count, 2)
    }

    // MARK: - YAML Deserialization Tests

    func testDeserializeYAMLObject() {
        let yaml = """
        id: 1
        name: Alice
        """
        let result = FormatDeserializer.deserialize(yaml, format: .yaml)

        guard let dict = result as? [String: any Sendable] else {
            XCTFail("Expected dictionary")
            return
        }
        XCTAssertEqual(dict["id"] as? Int, 1)
        XCTAssertEqual(dict["name"] as? String, "Alice")
    }

    // MARK: - CSV Deserialization Tests

    func testDeserializeCSVArray() {
        let csv = """
        id,name
        1,Alice
        2,Bob
        """
        let result = FormatDeserializer.deserialize(csv, format: .csv)

        guard let array = result as? [[String: any Sendable]] else {
            XCTFail("Expected array of dictionaries")
            return
        }
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0]["id"] as? Int, 1)
        XCTAssertEqual(array[0]["name"] as? String, "Alice")
    }

    func testDeserializeCSVKeyValue() {
        let csv = """
        key,value
        id,1
        name,Alice
        """
        let result = FormatDeserializer.deserialize(csv, format: .csv)

        guard let dict = result as? [String: any Sendable] else {
            XCTFail("Expected dictionary")
            return
        }
        XCTAssertEqual(dict["id"] as? Int, 1)
        XCTAssertEqual(dict["name"] as? String, "Alice")
    }

    // MARK: - Text Deserialization Tests

    func testDeserializeText() {
        let text = """
        id=1
        name=Alice
        """
        let result = FormatDeserializer.deserialize(text, format: .text)

        guard let dict = result as? [String: any Sendable] else {
            XCTFail("Expected dictionary")
            return
        }
        XCTAssertEqual(dict["id"] as? Int, 1)
        XCTAssertEqual(dict["name"] as? String, "Alice")
    }

    // MARK: - Non-Deserializable Formats

    func testMarkdownReturnsRawString() {
        let md = "| id | name |\n|---|---|\n| 1 | Alice |"
        let result = FormatDeserializer.deserialize(md, format: .markdown)

        XCTAssertEqual(result as? String, md)
    }

    func testHTMLReturnsRawString() {
        let html = "<table><tr><td>1</td></tr></table>"
        let result = FormatDeserializer.deserialize(html, format: .html)

        XCTAssertEqual(result as? String, html)
    }

    func testSQLReturnsRawString() {
        let sql = "INSERT INTO users (id) VALUES (1);"
        let result = FormatDeserializer.deserialize(sql, format: .sql)

        XCTAssertEqual(result as? String, sql)
    }
}

// MARK: - JSONL Format Tests

final class JSONLFormatTests: XCTestCase {

    func testDetectJSONL() {
        XCTAssertEqual(FileFormat.detect(from: "data.jsonl"), .jsonl)
        XCTAssertEqual(FileFormat.detect(from: "logs.ndjson"), .jsonl)
    }

    func testSerializeJSONLArray() {
        let data: [any Sendable] = [
            ["id": 1, "name": "Alice"] as [String: any Sendable],
            ["id": 2, "name": "Bob"] as [String: any Sendable]
        ]
        let jsonl = FormatSerializer.serialize(data, format: .jsonl, variableName: "users")

        let lines = jsonl.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"id\":1"))
        XCTAssertTrue(lines[0].contains("\"name\":\"Alice\""))
        XCTAssertTrue(lines[1].contains("\"id\":2"))
        XCTAssertTrue(lines[1].contains("\"name\":\"Bob\""))
    }

    func testSerializeJSONLSingleObject() {
        let data: [String: any Sendable] = ["id": 1, "name": "Alice"]
        let jsonl = FormatSerializer.serialize(data, format: .jsonl, variableName: "user")

        // Single object should be one line
        XCTAssertFalse(jsonl.contains("\n"))
        XCTAssertTrue(jsonl.contains("\"id\":1"))
        XCTAssertTrue(jsonl.contains("\"name\":\"Alice\""))
    }

    func testDeserializeJSONLArray() {
        let jsonl = """
        {"id":1,"name":"Alice"}
        {"id":2,"name":"Bob"}
        """
        let result = FormatDeserializer.deserialize(jsonl, format: .jsonl)

        guard let array = result as? [any Sendable] else {
            XCTFail("Expected array")
            return
        }
        XCTAssertEqual(array.count, 2)

        if let first = array[0] as? [String: any Sendable] {
            XCTAssertEqual(first["id"] as? Int, 1)
            XCTAssertEqual(first["name"] as? String, "Alice")
        } else {
            XCTFail("Expected dictionary")
        }
    }

    func testJSONLSupportsDeserialization() {
        XCTAssertTrue(FileFormat.jsonl.supportsDeserialization)
    }

    func testJSONLDisplayName() {
        XCTAssertEqual(FileFormat.jsonl.displayName, "JSON Lines")
    }
}

// MARK: - CSV Options Tests

final class CSVOptionsTests: XCTestCase {

    func testSerializeCSVWithCustomDelimiter() {
        let data: [any Sendable] = [
            ["id": 1, "name": "Alice"] as [String: any Sendable],
            ["id": 2, "name": "Bob"] as [String: any Sendable]
        ]
        let csv = FormatSerializer.serialize(
            data,
            format: .csv,
            variableName: "users",
            options: ["delimiter": ";"]
        )

        let lines = csv.split(separator: "\n")
        XCTAssertTrue(lines[0].contains(";"))
        XCTAssertFalse(lines[0].contains(","))
    }

    func testSerializeCSVWithoutHeader() {
        let data: [any Sendable] = [
            ["id": 1, "name": "Alice"] as [String: any Sendable],
            ["id": 2, "name": "Bob"] as [String: any Sendable]
        ]
        let csv = FormatSerializer.serialize(
            data,
            format: .csv,
            variableName: "users",
            options: ["header": false]
        )

        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2) // No header row
        XCTAssertFalse(lines[0].contains("id,name") || lines[0].contains("name,id"))
    }

    func testSerializeCSVWithCustomQuote() {
        let data: [any Sendable] = [
            ["id": 1, "name": "Alice, Bob"] as [String: any Sendable]
        ]
        let csv = FormatSerializer.serialize(
            data,
            format: .csv,
            variableName: "users",
            options: ["quote": "'"]
        )

        // Values with commas should be quoted with single quotes
        XCTAssertTrue(csv.contains("'Alice, Bob'"))
    }

    func testDeserializeCSVWithCustomDelimiter() {
        let csv = """
        id;name
        1;Alice
        2;Bob
        """
        let result = FormatDeserializer.deserialize(
            csv,
            format: .csv,
            options: ["delimiter": ";"]
        )

        guard let array = result as? [[String: any Sendable]] else {
            XCTFail("Expected array of dictionaries")
            return
        }
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0]["id"] as? Int, 1)
        XCTAssertEqual(array[0]["name"] as? String, "Alice")
    }

    func testDeserializeCSVWithoutHeader() {
        let csv = """
        1,Alice
        2,Bob
        """
        let result = FormatDeserializer.deserialize(
            csv,
            format: .csv,
            options: ["header": false]
        )

        guard let array = result as? [[any Sendable]] else {
            XCTFail("Expected array of arrays")
            return
        }
        XCTAssertEqual(array.count, 2)
        // Each row should be an array of values
        if let firstRow = array[0] as? [any Sendable] {
            XCTAssertEqual(firstRow.count, 2)
        }
    }

    func testDeserializeCSVWithCustomQuote() {
        let csv = """
        id,name
        1,'Alice, Bob'
        """
        let result = FormatDeserializer.deserialize(
            csv,
            format: .csv,
            options: ["quote": "'"]
        )

        guard let array = result as? [[String: any Sendable]] else {
            XCTFail("Expected array of dictionaries")
            return
        }
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(array[0]["name"] as? String, "Alice, Bob")
    }
}

// MARK: - Log Format Tests

final class LogFormatTests: XCTestCase {

    func testDetectLog() {
        XCTAssertEqual(FileFormat.detect(from: "app.log"), .log)
        XCTAssertEqual(FileFormat.detect(from: "server.log"), .log)
        XCTAssertEqual(FileFormat.detect(from: "/var/logs/system.log"), .log)
    }

    func testLogSupportsDeserialization() {
        // Log format is write-only
        XCTAssertFalse(FileFormat.log.supportsDeserialization)
    }

    func testLogDisplayName() {
        XCTAssertEqual(FileFormat.log.displayName, "Log")
    }

    func testSerializeLogString() {
        let message = "Server started"
        let result = FormatSerializer.serialize(message, format: .log, variableName: "message")

        // Should have ISO8601 timestamp followed by message
        XCTAssertTrue(result.contains(": Server started"))
        // Should start with a date (year)
        XCTAssertTrue(result.hasPrefix("20"))
    }

    func testSerializeLogArray() {
        let messages: [any Sendable] = ["Event 1", "Event 2", "Event 3"]
        let result = FormatSerializer.serialize(messages, format: .log, variableName: "events")

        let lines = result.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)

        // Each line should have timestamp and message
        XCTAssertTrue(lines[0].contains(": Event 1"))
        XCTAssertTrue(lines[1].contains(": Event 2"))
        XCTAssertTrue(lines[2].contains(": Event 3"))
    }

    func testSerializeLogObject() {
        let data: [String: any Sendable] = ["user": "Alice", "action": "login"]
        let result = FormatSerializer.serialize(data, format: .log, variableName: "event")

        // Object should be serialized as JSON
        XCTAssertTrue(result.contains(": {"))
        XCTAssertTrue(result.contains("\"user\""))
        XCTAssertTrue(result.contains("\"action\""))
    }

    func testDeserializeLogReturnsRawString() {
        let log = "2025-12-29T10:30:45Z: Server started"
        let result = FormatDeserializer.deserialize(log, format: .log)

        // Log format doesn't deserialize - returns raw string
        XCTAssertEqual(result as? String, log)
    }
}

// MARK: - Environment File Format Tests

final class EnvFormatTests: XCTestCase {

    func testDetectEnv() {
        XCTAssertEqual(FileFormat.detect(from: "config.env"), .env)
        XCTAssertEqual(FileFormat.detect(from: ".env"), .env)
        XCTAssertEqual(FileFormat.detect(from: "/path/to/.env"), .env)
    }

    func testEnvSupportsDeserialization() {
        XCTAssertTrue(FileFormat.env.supportsDeserialization)
    }

    func testEnvDisplayName() {
        XCTAssertEqual(FileFormat.env.displayName, "Environment")
    }

    func testSerializeEnvFlatObject() {
        let data: [String: any Sendable] = [
            "host": "localhost",
            "port": 8080,
            "debug": true
        ]

        let result = FormatSerializer.serialize(data, format: .env, variableName: "config")

        XCTAssertTrue(result.contains("DEBUG=true"))
        XCTAssertTrue(result.contains("HOST=localhost"))
        XCTAssertTrue(result.contains("PORT=8080"))
    }

    func testSerializeEnvNestedObject() {
        let data: [String: any Sendable] = [
            "database": [
                "host": "localhost",
                "port": 5432
            ] as [String: any Sendable],
            "apiKey": "secret123"
        ]

        let result = FormatSerializer.serialize(data, format: .env, variableName: "config")

        XCTAssertTrue(result.contains("API_KEY=secret123") || result.contains("APIKEY=secret123"))
        XCTAssertTrue(result.contains("DATABASE_HOST=localhost"))
        XCTAssertTrue(result.contains("DATABASE_PORT=5432"))
    }

    func testSerializeEnvUppercaseKeys() {
        let data: [String: any Sendable] = [
            "myKey": "value"
        ]

        let result = FormatSerializer.serialize(data, format: .env, variableName: "config")

        XCTAssertTrue(result.contains("MYKEY=value"))
        XCTAssertFalse(result.contains("myKey"))
    }

    func testDeserializeEnvBasic() {
        let env = """
        HOST=localhost
        PORT=8080
        DEBUG=true
        """

        let result = FormatDeserializer.deserialize(env, format: .env)
        let dict = result as? [String: any Sendable]

        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["HOST"] as? String, "localhost")
        XCTAssertEqual(dict?["PORT"] as? Int, 8080)
        XCTAssertEqual(dict?["DEBUG"] as? Bool, true)
    }

    func testDeserializeEnvWithComments() {
        let env = """
        # Database configuration
        DB_HOST=localhost
        # Port number
        DB_PORT=5432
        """

        let result = FormatDeserializer.deserialize(env, format: .env)
        let dict = result as? [String: any Sendable]

        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["DB_HOST"] as? String, "localhost")
        XCTAssertEqual(dict?["DB_PORT"] as? Int, 5432)
        XCTAssertNil(dict?["# Database configuration"])
    }

    func testDeserializeEnvWithQuotedValues() {
        let env = """
        NAME="John Doe"
        PATH='/usr/local/bin'
        """

        let result = FormatDeserializer.deserialize(env, format: .env)
        let dict = result as? [String: any Sendable]

        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["NAME"] as? String, "John Doe")
        XCTAssertEqual(dict?["PATH"] as? String, "/usr/local/bin")
    }

    func testDeserializeEnvWithEmptyLines() {
        let env = """
        KEY1=value1

        KEY2=value2

        """

        let result = FormatDeserializer.deserialize(env, format: .env)
        let dict = result as? [String: any Sendable]

        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["KEY1"] as? String, "value1")
        XCTAssertEqual(dict?["KEY2"] as? String, "value2")
    }
}
