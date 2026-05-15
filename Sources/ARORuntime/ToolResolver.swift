// ============================================================
// ToolResolver.swift
// ARO Runtime - Configurable Tool & Path Discovery
// ============================================================

import Foundation

/// Resolves external tool paths at runtime using environment variables,
/// `which`/`where` lookup, and hardcoded fallback paths.
///
/// Priority order for every lookup:
/// 1. Environment variable override (e.g. `ARO_CARGO_PATH`)
/// 2. `which` / `where` search on the user's PATH
/// 3. Platform-specific fallback paths
public enum ToolResolver {

    // MARK: - Tool Discovery

    /// Find an executable tool by name.
    ///
    /// - Parameters:
    ///   - name: The tool name (e.g. "cargo", "clang", "swiftc")
    ///   - envOverride: Optional environment variable that overrides lookup (e.g. "ARO_CARGO_PATH")
    ///   - fallbackPaths: Additional hardcoded paths to check after `which`
    /// - Returns: Absolute path to the tool, or nil if not found.
    public static func findTool(
        _ name: String,
        envOverride: String? = nil,
        fallbackPaths: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        // 1. Environment variable override
        if let envKey = envOverride,
           let envValue = environment[envKey],
           !envValue.isEmpty,
           FileManager.default.isExecutableFile(atPath: envValue) {
            return envValue
        }

        // 2. which / where lookup (uses the user's PATH)
        if let found = whichLookup(name) {
            return found
        }

        // 3. Hardcoded fallback paths
        for path in fallbackPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    // MARK: - Directory Resolution

    /// Resolve the directory containing a path, using URL APIs instead of NSString.
    public static func directoryOf(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    /// Append a path component to a base path using URL APIs.
    public static func join(_ base: String, _ component: String) -> String {
        URL(fileURLWithPath: base).appendingPathComponent(component).path
    }

    /// Resolve an executable path to an absolute directory, resolving symlinks.
    /// If `path` is relative, it is resolved against the current working directory.
    public static func resolveExecutableDirectory(_ path: String) -> String {
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            absolute = URL(fileURLWithPath: cwd).appendingPathComponent(path).path
        }
        let resolved = URL(fileURLWithPath: absolute).resolvingSymlinksInPath()
        return resolved.deletingLastPathComponent().path
    }

    // MARK: - Private

    /// Uses `/usr/bin/which` (Unix) or `C:\Windows\System32\where.exe` (Windows)
    /// to locate a tool on the user's PATH.
    private static func whichLookup(_ name: String) -> String? {
        let process = Process()
        #if os(Windows)
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\where.exe")
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        #endif
        process.arguments = [name]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }

        // `where` on Windows may return multiple lines; take the first
        let firstLine = output.components(separatedBy: .newlines).first ?? output
        return firstLine
    }
}
