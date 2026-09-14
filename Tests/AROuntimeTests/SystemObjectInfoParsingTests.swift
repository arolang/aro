// ============================================================
// SystemObjectInfoParsingTests.swift
// ARORuntimeTests - system_objects[] identity key (GitLab #556)
// ============================================================
//
// `SystemObjectDescriptor` calls the field `identifier`, and `parsePluginInfo`
// read only that key. No SDK emits it: the C SDK's info builder writes
// `{"name":…,"capabilities":…}` and the Python SDK's `@system_object` decorator
// records `"name"` too. Entries were therefore dropped by the `if let`,
// `systemObjects` stayed empty, and `providesSystemObject(_:)` was false for
// everything the plugin declared — so no plugin's system objects had ever
// registered through `aro_plugin_info`.

import Testing
import Foundation
@testable import ARORuntime

@Suite("system_objects[] identity key (GitLab #556)")
struct SystemObjectInfoParsingTests {

    private func parse(_ json: String) throws -> [SystemObjectDescriptor] {
        let dict = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return PluginInfoParser.parseSystemObjects(from: dict)
    }

    // MARK: - What the SDKs actually emit

    @Test("The C SDK's payload registers its system object")
    func cSdkPayloadRegisters() throws {
        // Copied from a cdylib built against aro-plugin-sdk-c:
        //   ARO_SYSTEM_OBJECT("hash-cache", "readable,writable")
        let objects = try parse("""
        {"name":"cachey","version":"1.0.0","language":"c","handle":"Cachey",
         "system_objects":[{"name":"hash-cache","capabilities":["readable","writable"]}]}
        """)

        #expect(objects.count == 1)
        #expect(objects.first?.identifier == "hash-cache")
        #expect(objects.first?.capabilities == ["readable", "writable"])
    }

    @Test("The canonical `identifier` key still registers")
    func identifierKeyRegisters() throws {
        let objects = try parse("""
        {"system_objects":[{"identifier":"hash-cache","capabilities":["readable"],
                            "description":"A cache"}]}
        """)

        #expect(objects.first?.identifier == "hash-cache")
        #expect(objects.first?.description == "A cache")
    }

    @Test("`identifier` wins when a plugin sends both")
    func identifierWins() throws {
        let objects = try parse("""
        {"system_objects":[{"identifier":"canonical","name":"other"}]}
        """)
        #expect(objects.first?.identifier == "canonical")
    }

    // MARK: - Edges

    @Test("An entry with neither key is dropped rather than registered blank")
    func neitherKeyIsDropped() throws {
        let objects = try parse(#"{"system_objects":[{"capabilities":["readable"]}]}"#)
        #expect(objects.isEmpty)
    }

    @Test("An empty identity is dropped too")
    func emptyIdentityIsDropped() throws {
        #expect(try parse(#"{"system_objects":[{"name":""}]}"#).isEmpty)
        #expect(try parse(#"{"system_objects":[{"identifier":""}]}"#).isEmpty)
    }

    @Test("A usable entry survives alongside an unusable one")
    func goodEntrySurvivesBadOne() throws {
        let objects = try parse("""
        {"system_objects":[{"capabilities":["readable"]},
                           {"name":"hash-cache"},
                           {"identifier":"config-store"}]}
        """)
        #expect(objects.map(\.identifier) == ["hash-cache", "config-store"])
    }

    @Test("Capabilities and description are optional")
    func optionalFields() throws {
        let objects = try parse(#"{"system_objects":[{"name":"bare"}]}"#)
        #expect(objects.first?.identifier == "bare")
        #expect(objects.first?.capabilities.isEmpty == true)
        #expect(objects.first?.description == nil)
    }

    @Test("No system_objects key at all is empty, not an error")
    func absentKeyIsEmpty() throws {
        #expect(try parse(#"{"name":"cachey","actions":[]}"#).isEmpty)
    }
}
