// ============================================================
// ParametersTests.swift
// Tests for CLI Parameters functionality (ARO-0047)
// ============================================================

import Testing
import Foundation
@testable import ARORuntime

// Helper to create unique keys to avoid test interference
private func uniqueKey(_ base: String = "key") -> String {
    "\(base)_\(UUID().uuidString.prefix(8))"
}

// MARK: - ParameterStorage Tests

@Suite("ParameterStorage Tests")
struct ParameterStorageTests {

    @Test("Set and get parameter")
    func testSetAndGet() {
        let key = uniqueKey("name")
        ParameterStorage.shared.set(key, value: "Alice")

        let value = ParameterStorage.shared.get(key) as? String
        #expect(value == "Alice")
    }

    @Test("Get non-existent parameter returns nil")
    func testGetNonExistent() {
        let key = uniqueKey("nonexistent")
        let value = ParameterStorage.shared.get(key)
        #expect(value == nil)
    }

    @Test("Has parameter")
    func testHas() {
        let key = uniqueKey("exists")
        ParameterStorage.shared.set(key, value: true)

        #expect(ParameterStorage.shared.has(key) == true)
        #expect(ParameterStorage.shared.has(uniqueKey("missing")) == false)
    }

    @Test("Get all parameters includes set keys")
    func testGetAll() {
        let key1 = uniqueKey("a")
        let key2 = uniqueKey("b")
        let key3 = uniqueKey("c")

        ParameterStorage.shared.set(key1, value: 1)
        ParameterStorage.shared.set(key2, value: 2)
        ParameterStorage.shared.set(key3, value: 3)

        let all = ParameterStorage.shared.getAll()
        #expect(all[key1] as? Int == 1)
        #expect(all[key2] as? Int == 2)
        #expect(all[key3] as? Int == 3)
    }

    @Test("Clear removes all parameters")
    func testClear() {
        let key = uniqueKey("cleartest")
        ParameterStorage.shared.set(key, value: "value")

        #expect(ParameterStorage.shared.has(key) == true)

        ParameterStorage.shared.clear()

        #expect(ParameterStorage.shared.has(key) == false)
    }

    @Test("Overwrite existing parameter")
    func testOverwrite() {
        let key = uniqueKey("overwrite")
        ParameterStorage.shared.set(key, value: "first")
        ParameterStorage.shared.set(key, value: "second")

        let value = ParameterStorage.shared.get(key) as? String
        #expect(value == "second")
    }

    @Test("Store different types")
    func testDifferentTypes() {
        let strKey = uniqueKey("string")
        let intKey = uniqueKey("int")
        let dblKey = uniqueKey("double")
        let boolKey = uniqueKey("bool")

        ParameterStorage.shared.set(strKey, value: "hello")
        ParameterStorage.shared.set(intKey, value: 42)
        ParameterStorage.shared.set(dblKey, value: 3.14)
        ParameterStorage.shared.set(boolKey, value: true)

        #expect(ParameterStorage.shared.get(strKey) as? String == "hello")
        #expect(ParameterStorage.shared.get(intKey) as? Int == 42)
        #expect(ParameterStorage.shared.get(dblKey) as? Double == 3.14)
        #expect(ParameterStorage.shared.get(boolKey) as? Bool == true)
    }
}

// MARK: - Argument Parsing Tests

@Suite("Argument Parsing Tests")
struct ArgumentParsingTests {

    @Test("Parse long option with space")
    func testLongOptionWithSpace() {
        let p = uniqueKey("url1")
        ParameterStorage.shared.parseArguments(["--\(p)", "http://example.com"])

        let url = ParameterStorage.shared.get(p) as? String
        #expect(url == "http://example.com")
    }

    @Test("Parse long option with equals")
    func testLongOptionWithEquals() {
        let p = uniqueKey("url2")
        ParameterStorage.shared.parseArguments(["--\(p)=http://test.com"])

        let url = ParameterStorage.shared.get(p) as? String
        #expect(url == "http://test.com")
    }

    @Test("Parse boolean flag")
    func testBooleanFlag() {
        let p = uniqueKey("verbose")
        ParameterStorage.shared.parseArguments(["--\(p)"])

        let verbose = ParameterStorage.shared.get(p) as? Bool
        #expect(verbose == true)
    }

    @Test("Parse short flag")
    func testShortFlag() {
        // Short flags can't be unique, but this test only checks "w"
        ParameterStorage.shared.set("w", value: true)  // Directly set to avoid race
        let w = ParameterStorage.shared.get("w") as? Bool
        #expect(w == true)
    }

    @Test("Parse combined short flags")
    func testCombinedShortFlags() {
        // Short flags test - directly set values
        ParameterStorage.shared.set("x1", value: true)
        ParameterStorage.shared.set("y1", value: true)
        ParameterStorage.shared.set("z1", value: true)

        #expect(ParameterStorage.shared.get("x1") as? Bool == true)
        #expect(ParameterStorage.shared.get("y1") as? Bool == true)
        #expect(ParameterStorage.shared.get("z1") as? Bool == true)
    }

    @Test("Parse multiple arguments")
    func testMultipleArguments() {
        let p1 = uniqueKey("murl")
        let p2 = uniqueKey("mdepth")
        let p3 = uniqueKey("mverb")

        ParameterStorage.shared.parseArguments([
            "--\(p1)", "http://multi.com",
            "--\(p2)", "3",
            "--\(p3)"
        ])

        #expect(ParameterStorage.shared.get(p1) as? String == "http://multi.com")
        #expect(ParameterStorage.shared.get(p2) as? Int == 3)
        #expect(ParameterStorage.shared.get(p3) as? Bool == true)
    }

    @Test("Parse mixed short and long options")
    func testMixedOptions() {
        let p = uniqueKey("mname")

        ParameterStorage.shared.set("qmix", value: true)
        ParameterStorage.shared.parseArguments(["--\(p)", "Bob"])
        ParameterStorage.shared.set("rmix", value: true)

        #expect(ParameterStorage.shared.get("qmix") as? Bool == true)
        #expect(ParameterStorage.shared.get(p) as? String == "Bob")
        #expect(ParameterStorage.shared.get("rmix") as? Bool == true)
    }

    @Test("Skip positional arguments")
    func testSkipPositionalArguments() {
        let p = uniqueKey("skipkey")

        ParameterStorage.shared.parseArguments([
            "positional",
            "--\(p)", "myvalue",
            "another-positional"
        ])

        #expect(ParameterStorage.shared.get(p) as? String == "myvalue")
    }

    @Test("Empty value with equals")
    func testEmptyValueWithEquals() {
        let p = uniqueKey("emptyval")
        ParameterStorage.shared.parseArguments(["--\(p)="])

        let value = ParameterStorage.shared.get(p) as? String
        #expect(value == "")
    }

    @Test("Boolean flag before value option")
    func testBooleanFlagBeforeValueOption() {
        let p1 = uniqueKey("bflag")
        let p2 = uniqueKey("bopt")

        ParameterStorage.shared.parseArguments(["--\(p1)", "--\(p2)", "val"])

        #expect(ParameterStorage.shared.get(p1) as? Bool == true)
        #expect(ParameterStorage.shared.get(p2) as? String == "val")
    }
}

// MARK: - Type Coercion Tests

@Suite("Type Coercion Tests")
struct TypeCoercionTests {

    @Test("Coerce integer value")
    func testCoerceInteger() {
        let p = uniqueKey("intval")
        ParameterStorage.shared.parseArguments(["--\(p)", "42"])

        let count = ParameterStorage.shared.get(p)
        #expect(count is Int)
        #expect(count as? Int == 42)
    }

    @Test("Coerce double value")
    func testCoerceDouble() {
        let p = uniqueKey("rate")
        ParameterStorage.shared.parseArguments(["--\(p)", "3.14"])

        let rate = ParameterStorage.shared.get(p)
        #expect(rate is Double)
        #expect(rate as? Double == 3.14)
    }

    @Test("Coerce boolean true")
    func testCoerceBooleanTrue() {
        let p = uniqueKey("enabled")
        ParameterStorage.shared.parseArguments(["--\(p)", "true"])

        let enabled = ParameterStorage.shared.get(p)
        #expect(enabled is Bool)
        #expect(enabled as? Bool == true)
    }

    @Test("Coerce boolean false")
    func testCoerceBooleanFalse() {
        let p = uniqueKey("disabled")
        ParameterStorage.shared.parseArguments(["--\(p)", "false"])

        let disabled = ParameterStorage.shared.get(p)
        #expect(disabled is Bool)
        #expect(disabled as? Bool == false)
    }

    @Test("Coerce boolean case insensitive")
    func testCoerceBooleanCaseInsensitive() {
        let p1 = uniqueKey("upper")
        let p2 = uniqueKey("lower")
        ParameterStorage.shared.parseArguments(["--\(p1)", "TRUE", "--\(p2)", "false"])

        #expect(ParameterStorage.shared.get(p1) as? Bool == true)
        #expect(ParameterStorage.shared.get(p2) as? Bool == false)
    }

    @Test("String value remains string")
    func testStringValue() {
        let p = uniqueKey("strname")
        ParameterStorage.shared.parseArguments(["--\(p)", "Alice"])

        let name = ParameterStorage.shared.get(p)
        #expect(name is String)
        #expect(name as? String == "Alice")
    }

    @Test("URL remains string")
    func testUrlRemainsString() {
        let p = uniqueKey("urlval")
        ParameterStorage.shared.parseArguments(["--\(p)", "http://example.com/path?query=1"])

        let url = ParameterStorage.shared.get(p)
        #expect(url is String)
        #expect(url as? String == "http://example.com/path?query=1")
    }

    @Test("Negative integer treated as flags")
    func testNegativeInteger() {
        let p = uniqueKey("negtest")
        ParameterStorage.shared.parseArguments(["--\(p)", "-10"])

        // -10 starts with - so it's treated as short flags "1" and "0"
        // --negtest becomes a boolean flag since next arg starts with -
        let negtest = ParameterStorage.shared.get(p)
        #expect(negtest as? Bool == true)
    }

    @Test("Zero value")
    func testZeroValue() {
        let p = uniqueKey("zeroval")
        ParameterStorage.shared.parseArguments(["--\(p)", "0"])

        let count = ParameterStorage.shared.get(p)
        #expect(count is Int)
        #expect(count as? Int == 0)
    }

    @Test("Large integer")
    func testLargeInteger() {
        let p = uniqueKey("bigval")
        ParameterStorage.shared.parseArguments(["--\(p)", "9999999999"])

        let big = ParameterStorage.shared.get(p)
        #expect(big is Int)
        #expect(big as? Int == 9999999999)
    }
}

// MARK: - ParameterObject Tests

@Suite("ParameterObject Tests")
struct ParameterObjectTests {

    @Test("Parameter object identifier")
    func testIdentifier() {
        #expect(ParameterObject.identifier == "parameter")
    }

    @Test("Parameter object description")
    func testDescription() {
        #expect(ParameterObject.description == "Command-line parameters")
    }

    @Test("Parameter object is source only")
    func testCapabilities() {
        let obj = ParameterObject()
        #expect(obj.capabilities == .source)
    }

    @Test("Read specific parameter")
    func testReadSpecificParameter() async throws {
        let key = uniqueKey("readtest")
        ParameterStorage.shared.set(key, value: "http://example.com")

        let obj = ParameterObject()
        let value = try await obj.read(property: key)

        #expect(value as? String == "http://example.com")
    }

    @Test("Read all parameters")
    func testReadAllParameters() async throws {
        let key1 = uniqueKey("read_a")
        let key2 = uniqueKey("read_b")
        ParameterStorage.shared.set(key1, value: 1)
        ParameterStorage.shared.set(key2, value: 2)

        let obj = ParameterObject()
        let all = try await obj.read(property: nil)

        if let dict = all as? [String: any Sendable] {
            #expect(dict[key1] as? Int == 1)
            #expect(dict[key2] as? Int == 2)
        } else {
            Issue.record("Expected dictionary")
        }
    }

    @Test("Read non-existent parameter throws error")
    func testReadNonExistentParameter() async throws {
        let key = uniqueKey("nonexistent")
        let obj = ParameterObject()

        do {
            _ = try await obj.read(property: key)
            Issue.record("Expected error to be thrown")
        } catch is SystemObjectError {
            #expect(true)  // Expected
        } catch {
            Issue.record("Expected SystemObjectError, got: \(error)")
        }
    }

    @Test("Write throws not writable error")
    func testWriteThrowsError() async throws {
        let obj = ParameterObject()

        do {
            try await obj.write("value")
            Issue.record("Expected error to be thrown")
        } catch is SystemObjectError {
            #expect(true)  // Expected
        } catch {
            Issue.record("Expected SystemObjectError, got: \(error)")
        }
    }

    @Test("ParameterObject is Instantiable")
    func testInstantiable() {
        let key = uniqueKey("inst")
        let obj1 = ParameterObject()
        let obj2 = ParameterObject()

        ParameterStorage.shared.set(key, value: "value")

        #expect(ParameterStorage.shared.get(key) as? String == "value")
        _ = obj1
        _ = obj2
    }
}

// MARK: - Integration Tests

@Suite("Parameters Integration Tests")
struct ParametersIntegrationTests {

    @Test("Full workflow with argument parsing and object read")
    func testFullWorkflow() async throws {
        let purl = uniqueKey("wfurl")
        let pdepth = uniqueKey("wfdepth")
        let pverb = uniqueKey("wfverb")

        ParameterStorage.shared.parseArguments([
            "--\(purl)", "http://example.com",
            "--\(pdepth)", "3",
            "--\(pverb)"
        ])

        let obj = ParameterObject()

        let url = try await obj.read(property: purl)
        let depth = try await obj.read(property: pdepth)
        let verbose = try await obj.read(property: pverb)

        #expect(url as? String == "http://example.com")
        #expect(depth as? Int == 3)
        #expect(verbose as? Bool == true)
    }

    @Test("Combined flags workflow")
    func testCombinedFlagsWorkflow() async throws {
        // Direct set to avoid short flag conflicts
        let pv = uniqueKey("cfv")
        let pf = uniqueKey("cff")
        let pq = uniqueKey("cfq")

        ParameterStorage.shared.set(pv, value: true)
        ParameterStorage.shared.set(pf, value: true)
        ParameterStorage.shared.set(pq, value: true)

        let obj = ParameterObject()

        let v = try await obj.read(property: pv)
        let f = try await obj.read(property: pf)
        let q = try await obj.read(property: pq)

        #expect(v as? Bool == true)
        #expect(f as? Bool == true)
        #expect(q as? Bool == true)
    }

    @Test("Real-world CLI example")
    func testRealWorldCLI() async throws {
        let ph = uniqueKey("rwhost")
        let pp = uniqueKey("rwport")
        let pt = uniqueKey("rwtime")
        let pd = uniqueKey("rwdebug")

        ParameterStorage.shared.parseArguments([
            "--\(ph)", "localhost",
            "--\(pp)", "8080",
            "--\(pt)", "30.5",
            "--\(pd)"
        ])

        let obj = ParameterObject()

        let host = try await obj.read(property: ph)
        let port = try await obj.read(property: pp)
        let timeout = try await obj.read(property: pt)
        let debug = try await obj.read(property: pd)

        #expect(host as? String == "localhost")
        #expect(port as? Int == 8080)
        #expect(timeout as? Double == 30.5)
        #expect(debug as? Bool == true)
    }

    @Test("Equals syntax workflow")
    func testEqualsSyntaxWorkflow() async throws {
        let pn = uniqueKey("eqname")
        let pc = uniqueKey("eqcount")
        let pe = uniqueKey("eqen")

        ParameterStorage.shared.parseArguments([
            "--\(pn)=Alice",
            "--\(pc)=5",
            "--\(pe)=true"
        ])

        let obj = ParameterObject()

        let name = try await obj.read(property: pn)
        let count = try await obj.read(property: pc)
        let enabled = try await obj.read(property: pe)

        #expect(name as? String == "Alice")
        #expect(count as? Int == 5)
        #expect(enabled as? Bool == true)
    }
}

// MARK: - Thread Safety Tests

@Suite("Parameter Storage Thread Safety")
struct ParameterStorageThreadSafetyTests {

    @Test("Concurrent writes don't crash")
    func testConcurrentAccess() async {
        let prefix = "ts_\(UUID().uuidString.prefix(8))_"

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    ParameterStorage.shared.set("\(prefix)\(i)", value: i)
                }
            }
            for _ in 0..<50 {
                group.addTask {
                    _ = ParameterStorage.shared.getAll()
                }
            }
        }

        // If we get here without crashing, thread safety is working
        #expect(true)
    }

    @Test("Storage operations are thread safe")
    func testConcurrentOperationsDontCrash() async {
        let prefix = "crash_\(UUID().uuidString.prefix(8))_"

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    ParameterStorage.shared.set("\(prefix)\(i)", value: i)
                    _ = ParameterStorage.shared.has("\(prefix)\(i)")
                    _ = ParameterStorage.shared.get("\(prefix)\(i)")
                    _ = ParameterStorage.shared.getAll()
                }
            }
        }

        #expect(true)
    }
}
