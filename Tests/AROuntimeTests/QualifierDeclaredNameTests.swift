// ============================================================
// QualifierDeclaredNameTests.swift
// ARORuntimeTests - a plugin gets its qualifier's declared name (GitLab #553)
// ============================================================
//
// A qualifier's name crosses the plugin boundary as a *string looked up in the
// plugin's own registry*, and every SDK keys that registry by the name as
// declared. Two things in the runtime rewrote the name on the way out:
//
//   * `QualifierRegistration.init` lowercases it, because ARO resolves
//     `<x: Handle.Qualifier>` case-insensitively and the registry keys on the
//     lowercased form — but `resolve` then sent that key to the plugin, so
//     `toHtml` was asked for as `tohtml`.
//   * `PythonPluginHost.executeQualifier` snake-cased it on top, so
//     `pick-random` went out as `pick_random`.
//
// Either way the plugin answered `{"error": "Unknown qualifier: …"}` and the
// author was told a qualifier they had declared did not exist. Any name that
// was not one all-lowercase word was unreachable.

import Testing
import Foundation
@testable import ARORuntime

/// Records the qualifier name it is asked for, and echoes it back as the value.
private final class NameRecordingHost: PluginQualifierHost, @unchecked Sendable {
    let pluginName = "namey"
    private let lock = NSLock()
    private var seen: [String] = []

    var namesAsked: [String] { lock.lock(); defer { lock.unlock() }; return seen }

    func executeQualifier(
        _ qualifier: String,
        input: any Sendable,
        withParams: [String: any Sendable]?
    ) throws -> any Sendable {
        lock.lock(); seen.append(qualifier); lock.unlock()
        return qualifier
    }
}

@Suite("Plugin qualifiers keep their declared name (GitLab #553)", .serialized)
struct QualifierDeclaredNameTests {

    private func register(_ declared: String, host: NameRecordingHost) {
        QualifierRegistry.shared.register(
            QualifierRegistration(
                qualifier: declared,
                inputTypes: [.string, .list],
                pluginName: "namey",
                namespace: "Namey",
                pluginHost: host
            )
        )
    }

    // MARK: - The declared name reaches the plugin

    @Test("A camelCase qualifier is asked for as declared, not lowercased")
    func camelCaseSurvives() throws {
        let host = NameRecordingHost()
        register("toHtml", host: host)
        defer { QualifierRegistry.shared.unregisterPlugin("namey") }

        _ = try QualifierRegistry.shared.resolve("namey.tohtml", value: "hi")
        #expect(host.namesAsked == ["toHtml"])
    }

    @Test("A hyphenated qualifier is asked for as declared")
    func hyphenSurvives() throws {
        let host = NameRecordingHost()
        register("pick-random", host: host)
        defer { QualifierRegistry.shared.unregisterPlugin("namey") }

        _ = try QualifierRegistry.shared.resolve("namey.pick-random", value: ["a", "b"])
        #expect(host.namesAsked == ["pick-random"])
    }

    @Test("A single lowercase word is unchanged — the case that always worked")
    func singleWordUnchanged() throws {
        let host = NameRecordingHost()
        register("shout", host: host)
        defer { QualifierRegistry.shared.unregisterPlugin("namey") }

        _ = try QualifierRegistry.shared.resolve("namey.shout", value: "hi")
        #expect(host.namesAsked == ["shout"])
    }

    // MARK: - ARO-side resolution stays case-insensitive

    @Test("Source may spell the qualifier in any case and still resolve")
    func aroLookupStaysCaseInsensitive() throws {
        let host = NameRecordingHost()
        register("toHtml", host: host)
        defer { QualifierRegistry.shared.unregisterPlugin("namey") }

        for spelling in ["namey.toHtml", "namey.tohtml", "NAMEY.TOHTML", "Namey.ToHtml"] {
            let out = try QualifierRegistry.shared.resolve(spelling, value: "hi")
            #expect(out as? String == "toHtml", "\(spelling) did not resolve")
        }
        // Every one of them asked the plugin for the declared spelling.
        #expect(host.namesAsked == Array(repeating: "toHtml", count: 4))
    }

    // MARK: - The registration keeps both forms

    @Test("The registration holds the lowercased key and the declared name side by side")
    func registrationKeepsBoth() {
        let reg = QualifierRegistration(
            qualifier: "toHtml",
            inputTypes: [.string],
            pluginName: "namey",
            namespace: "Namey",
            pluginHost: NameRecordingHost()
        )
        #expect(reg.qualifier == "tohtml")           // the key ARO resolves against
        #expect(reg.declaredQualifier == "toHtml")   // what the plugin is asked for
        #expect(reg.namespace == "namey")
    }
}
