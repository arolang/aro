// ============================================================
// PluginSymbolRenamerTests.swift
// AROCompiler — batched plugin symbol renaming (GitLab #716)
// ============================================================

import Testing
import Foundation
@testable import AROCompiler

@Suite("Plugin symbol renaming")
struct PluginSymbolRenamerTests {

    // MARK: - The redefinition map

    @Test("Map lists every plugin symbol as an `old new` pair")
    func mapCoversEverySymbol() {
        let map = PluginSymbolRenamer.redefineSymsMap(pluginName: "demo")
        let lines = map.split(separator: "\n").map(String.init)

        for sym in PluginSymbolRenamer.pluginSymbols {
            let renamed = PluginSymbolRenamer.renamedSymbol(plugin: "demo", original: sym)
            #expect(lines.contains("\(sym) \(renamed)"),
                    "map is missing the ELF spelling of \(sym)")
            #if os(macOS)
            #expect(lines.contains("_\(sym) _\(renamed)"),
                    "map is missing the Mach-O spelling of \(sym)")
            #endif
        }

        // Every line must be exactly two whitespace-separated fields, which is
        // the format llvm-objcopy's --redefine-syms file parser accepts.
        for line in lines {
            #expect(line.split(separator: " ").count == 2, "malformed map line: \(line)")
        }
    }

    @Test("Map ends with a newline so the last pair is not dropped")
    func mapEndsWithNewline() {
        #expect(PluginSymbolRenamer.redefineSymsMap(pluginName: "demo").hasSuffix("\n"))
    }

    // MARK: - Renaming, both paths

    /// Renames more object files than `archiveBatchThreshold`, so the batched
    /// archive round-trip runs, and fewer than it, so the per-file loop runs.
    /// Both must produce the same file names and the same renamed symbols —
    /// that equivalence is what makes the batching in GitLab #716 safe.
    @Test("Batched and per-file renaming agree", .enabled(if: Toolchain.available))
    func batchedAndPerFileAgree() throws {
        let renamer = PluginSymbolRenamer()

        for count in [3, PluginSymbolRenamer.archiveBatchThreshold + 4] {
            let work = try Toolchain.makeTempDir()
            defer { try? FileManager.default.removeItem(at: work) }

            let objects = try Toolchain.makeObjectFiles(count: count, in: work)
            let outDir = work.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            let renamed = try renamer.renamePluginSymbols(
                objectFiles: objects, pluginName: "demo", outputDir: outDir.path)

            #expect(renamed.count == count)
            for (index, path) in renamed.enumerated() {
                #expect(URL(fileURLWithPath: path).lastPathComponent
                        == "demo_\(index)_obj\(index).o")
                #expect(FileManager.default.fileExists(atPath: path))
            }

            // The renamed symbol must actually be in the objects, and the
            // original must be gone — otherwise two plugins would still collide.
            let symbols = try renamer.discoverSymbols(in: renamed, pluginName: "demo")
            #expect(symbols.contains("aro_plugin_info"))

            let dump = Toolchain.nm(renamed)
            #expect(dump.contains("aro_static_demo__aro_plugin_info"))
            #expect(!dump.contains(" _aro_plugin_info\n") && !dump.contains(" aro_plugin_info\n"))
        }
    }

    @Test("Renaming no object files is not an error")
    func emptyInput() throws {
        #expect(try PluginSymbolRenamer().renamePluginSymbols(
            objectFiles: [], pluginName: "demo", outputDir: NSTemporaryDirectory()).isEmpty)
    }
}

// MARK: - Toolchain helpers

/// The renaming tests need a C compiler plus llvm-objcopy/llvm-ar. Those are
/// present wherever `aro build` works, but the unit suite must still run on a
/// machine without them, so the tests that need them are gated on this.
private enum Toolchain {

    static var available: Bool {
        which("clang") != nil && which("llvm-objcopy") != nil && which("llvm-ar") != nil
    }

    static func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-renamer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `count` distinct .o files, each defining the plugin entry point.
    static func makeObjectFiles(count: Int, in dir: URL) throws -> [String] {
        guard let clang = which("clang") else { return [] }
        var paths: [String] = []
        for i in 0..<count {
            let source = dir.appendingPathComponent("obj\(i).c")
            try "const char *aro_plugin_info(void) { return \"\(i)\"; }\n"
                .write(to: source, atomically: true, encoding: .utf8)
            let object = dir.appendingPathComponent("obj\(i).o")
            run([clang, "-c", "-o", object.path, source.path])
            paths.append(object.path)
        }
        return paths
    }

    static func nm(_ files: [String]) -> String {
        let pipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        #if os(macOS)
        p.arguments = ["-gU"] + files
        #else
        p.arguments = ["-g", "--defined-only"] + files
        #endif
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func which(_ tool: String) -> String? {
        let pipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [tool]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }
}
