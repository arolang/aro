// ============================================================
// DynamicLoadingTests.swift
// ARORuntime - Link mode decides plugin loadability (GitLab #618)
// ============================================================
//
// The rule is exercised through `canLoadPlugin(ofType:linkedAs:)` rather than
// through the process-wide recorded mode: swift-testing runs a suite's tests in
// parallel, so a test that had to record a link mode first would race every
// sibling that reads one.

import Testing
import Foundation
@testable import ARORuntime

@Suite("DynamicLoading — link mode, not a dlopen probe (#618)")
struct DynamicLoadingTests {

    private static let nativePluginTypes = ["c-plugin", "cpp-plugin", "rust-plugin"]

    @Test("the interpreter loads every kind of plugin")
    func interpreterLoadsEverything() {
        for type in Self.nativePluginTypes + ["swift-plugin"] {
            #expect(DynamicLoading.canLoadPlugin(ofType: type, linkedAs: .interpreter))
        }
    }

    @Test("a --dynamic binary loads every kind of plugin")
    func dynamicBinaryLoadsEverything() {
        for type in Self.nativePluginTypes + ["swift-plugin"] {
            #expect(DynamicLoading.canLoadPlugin(ofType: type, linkedAs: .dynamic))
        }
    }

    @Test("a --static binary refuses a Swift plugin")
    func staticBinaryRefusesSwiftPlugin() {
        // The host baked libswiftCore in; the plugin's shared object links it
        // dynamically. Loading it would put two Swift runtimes in one process.
        #expect(!DynamicLoading.canLoadPlugin(ofType: "swift-plugin", linkedAs: .static))
    }

    @Test("a --static binary still loads plugins that bring no Swift runtime")
    func staticBinaryLoadsCAndRustPlugins() {
        for type in Self.nativePluginTypes {
            #expect(
                DynamicLoading.canLoadPlugin(ofType: type, linkedAs: .static),
                "expected a \(type) to remain loadable from a static binary"
            )
        }
    }

    @Test("the default link mode is the interpreter")
    func defaultsToInterpreter() {
        // Nothing but a compiled binary's generated main records a mode, so a
        // test process is the interpreter.
        #expect(DynamicLoading.linkMode == .interpreter)
    }

    @Test("aro_set_build_link_mode accepts exactly the names the compiler emits")
    func linkModeRawValues() {
        #expect(AROLinkMode(rawValue: "static") == .static)
        #expect(AROLinkMode(rawValue: "dynamic") == .dynamic)
        #expect(AROLinkMode(rawValue: "interpreter") == .interpreter)
        // Anything else leaves the recorded mode alone rather than guessing.
        #expect(AROLinkMode(rawValue: "staticLink") == nil)
        #expect(AROLinkMode(rawValue: "") == nil)
    }

    @Test("the refusal names the plugin and points at --dynamic")
    func refusalIsActionable() {
        let message = DynamicLoading.unavailableReason(
            plugin: "plugin-swift-hello", pluginType: "swift-plugin"
        )
        #expect(message.contains("plugin-swift-hello"))
        #expect(message.contains("swift-plugin"))
        #expect(message.contains("--dynamic"))
        // It must describe this platform's shared object, not the other one.
        #if os(macOS)
        #expect(message.contains(".dylib"))
        #expect(!message.contains(".so"))
        #else
        #expect(message.contains(".so"))
        #expect(!message.contains(".dylib"))
        #endif
    }
}
