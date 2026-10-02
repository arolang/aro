// ============================================================
// ToolResolver+WorkingDirectory.swift
// ARO Runtime - Executable-relative path resolution
// ============================================================

import Foundation
import AROToolchain

/// `ToolResolver` itself lives in `AROToolchain`, a leaf module the compiler, the
/// package manager and the runtime can all reach (GitLab #733). This one helper
/// stays behind because it resolves against `AROWorkingDirectory`, which is the
/// runtime's notion of where a compiled binary thinks it is running.
extension ToolResolver {

    /// Resolve an executable path to an absolute directory, resolving symlinks.
    /// If `path` is relative, it is resolved against the current working directory.
    public static func resolveExecutableDirectory(_ path: String) -> String {
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else {
            let cwd = AROWorkingDirectory.base
            absolute = URL(fileURLWithPath: cwd).appendingPathComponent(path).path
        }
        let resolved = URL(fileURLWithPath: absolute).resolvingSymlinksInPath()
        return resolved.deletingLastPathComponent().path
    }
}
