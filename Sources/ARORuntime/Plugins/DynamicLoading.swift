// ============================================================
// DynamicLoading.swift
// ARO Runtime - Can this binary load a plugin shared object? (GitLab #618)
// ============================================================
//
// Whether a process may load a plugin `.so` / `.dylib` after the build is
// settled at *link* time, not at run time. Asking the loader — "does
// `dlopen(nil, …)` hand back a handle?" — answers a different question. It
// establishes "this process can resolve symbols in its own image right now",
// which is true in plenty of binaries that must never `dlopen` a plugin: on
// glibc a statically linked program still has a `dlopen` that returns a
// handle, and the damage only surfaces later, inside the load.
//
// So the answer travels with the binary instead of being guessed from it.
// `aro build` emits a call to `aro_set_build_link_mode` at the top of the
// generated `main`; `aro run` never calls it and keeps the `.interpreter`
// default. Everything that wants to know asks `DynamicLoading`, which answers
// from the recorded fact and explains itself in the terms of the platform it
// is running on.

import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// How the executable that is running right now was produced.
public enum AROLinkMode: String, Sendable {
    /// `aro run`, `aro test`, `aro repl` — an ordinary dynamically linked
    /// process hosting the interpreter. Plugins are loaded with `dlopen`, which
    /// is how the interpreter has always worked.
    case interpreter = "interpreter"

    /// `aro build --dynamic`. The Swift runtime is bound as shared libraries
    /// (bundled next to the binary on Linux), so a plugin shared object that
    /// links the same runtime shares it with the host.
    case dynamic = "dynamic"

    /// `aro build --static` (the default). The Swift runtime is baked into the
    /// executable as archives; the result is meant to be one file you copy.
    case `static` = "static"
}

/// The build-time link mode of this process, and what it implies for loading
/// plugin shared objects after the build.
public enum DynamicLoading {

    // MARK: - The recorded fact

    /// How this executable was linked, as recorded by `aro build`.
    ///
    /// Defaults to `.interpreter`: a process that never ran the generated
    /// `main` is the interpreter by definition.
    public static var linkMode: AROLinkMode {
        linkModeLock.lock()
        defer { linkModeLock.unlock() }
        return recordedLinkMode
    }

    /// Record the link mode. Called once, from the generated `main`, before any
    /// plugin is registered or loaded.
    public static func recordLinkMode(_ mode: AROLinkMode) {
        linkModeLock.lock()
        defer { linkModeLock.unlock() }
        recordedLinkMode = mode
    }

    // MARK: - What it implies

    /// Whether this binary may `dlopen` a plugin of the given manifest type
    /// (`swift-plugin`, `c-plugin`, `cpp-plugin`, `rust-plugin`, …).
    ///
    /// The interpreter and a `--dynamic` binary load anything. A `--static`
    /// binary carries its own copy of the Swift runtime, so it can still load a
    /// plugin that brings no runtime of its own (C, C++, Rust) but must not
    /// load a Swift plugin: the plugin's shared object links `libswiftCore`
    /// dynamically, and the process would end up holding two Swift runtimes
    /// with two sets of type metadata.
    ///
    /// Note this deliberately does *not* consult `dlopen`. Whether the loader
    /// happens to answer is not the question being asked.
    public static func canLoadPlugin(ofType pluginType: String) -> Bool {
        canLoadPlugin(ofType: pluginType, linkedAs: linkMode)
    }

    /// The rule itself, over an explicit link mode.
    ///
    /// Split out so it can be exercised on a value rather than on the recorded
    /// process-wide one: tests run in parallel, and a test that had to record a
    /// link mode first would race every sibling that reads it.
    public static func canLoadPlugin(ofType pluginType: String, linkedAs mode: AROLinkMode) -> Bool {
        switch mode {
        case .interpreter, .dynamic:
            return true
        case .static:
            return !pluginBringsOwnSwiftRuntime(pluginType)
        }
    }

    /// Why `canLoadPlugin(ofType:)` said no, phrased for the platform this is
    /// printed on — `--dynamic` means different things on macOS and Linux, and
    /// a message that names the wrong one sends the reader down a dead end.
    public static func unavailableReason(plugin: String, pluginType: String) -> String {
        #if os(macOS)
        let sharedObject = ".dylib"
        let dynamicMeaning =
            "`--dynamic` links the Swift runtime as the toolchain's dylibs instead of baking it in"
        #else
        let sharedObject = ".so"
        let dynamicMeaning =
            "`--dynamic` links the Swift runtime as shared objects and bundles them next to the binary"
        #endif

        return """
            Plugin '\(plugin)' (\(pluginType)) cannot be loaded into this binary.
              It was linked with `aro build --static` (the default), which bakes the Swift
              runtime into the executable, and a Swift plugin \(sharedObject) links that runtime
              dynamically — loading it would put two copies of libswiftCore in one process.
              Either keep the plugin in Plugins/ so `aro build` bakes it into the binary,
              or rebuild with `aro build --dynamic` (\(dynamicMeaning)).
            """
    }

    // MARK: - Private

    /// Whether a plugin of this manifest type ships its own Swift runtime
    /// dependency. Only Swift plugins do; C, C++ and Rust plugins are plain
    /// C-ABI shared objects.
    static func pluginBringsOwnSwiftRuntime(_ pluginType: String) -> Bool {
        pluginType == "swift-plugin"
    }
}

private let linkModeLock = NSLock()
private nonisolated(unsafe) var recordedLinkMode: AROLinkMode = .interpreter

/// Record the link mode chosen by `aro build`. Emitted by the code generator as
/// the first call in `main`, before any plugin registration, so every later
/// question about dynamic loading is answered from the build's own decision.
///
/// An unrecognised string leaves the default in place rather than guessing.
@_cdecl("aro_set_build_link_mode")
public func aro_set_build_link_mode(_ modePtr: UnsafePointer<CChar>?) {
    guard let modePtr, let mode = AROLinkMode(rawValue: String(cString: modePtr)) else { return }
    DynamicLoading.recordLinkMode(mode)
}
