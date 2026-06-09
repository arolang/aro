// ============================================================
// solaro — tiny launcher CLI alongside the .app  (issue #228)
// ============================================================
//
// ADR-001/008 follow-up: SOLARO is a desktop app, but terminal users
// want `cd project && solaro .` without making SOLARO a subcommand
// of `aro`. This binary is that affordance — ~20 LOC that does the
// platform-correct "open the app with this path" dance.
//
// Behavior:
//   solaro             → opens SOLARO with no project
//   solaro .           → opens SOLARO with the current directory
//   solaro <path>      → opens SOLARO with <path>
//   solaro --help      → prints this usage
//   solaro --version   → prints the version of the launcher itself

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let argv = CommandLine.arguments
let progname = (argv.first as NSString?)?.lastPathComponent ?? "solaro"

func usage() {
    print("""
    \(progname) — launcher for the SOLARO desktop app.

    Usage:
      \(progname) [<path>]
      \(progname) --help | --version

    With no argument, opens SOLARO with no project. With a path,
    opens SOLARO and immediately loads that project.

    The launcher is a thin shim — SOLARO itself is the .app /
    .AppImage / .msi distributed separately. If the launcher
    cannot locate the SOLARO bundle (env var SOLARO_APP, $PATH,
    standard install locations), it prints a diagnostic and exits
    non-zero.
    """)
}

if argv.contains("--help") || argv.contains("-h") {
    usage()
    exit(0)
}

if argv.contains("--version") {
    print("solaro launcher 0.1.0")
    exit(0)
}

// Resolve the path the user wants to open. Empty when no arg given.
let argPath: String
if argv.count >= 2 {
    argPath = argv[1] == "." ? FileManager.default.currentDirectoryPath : argv[1]
} else {
    argPath = ""
}

#if os(macOS)

// 1. Honor SOLARO_APP env var first — point at a specific .app bundle.
// 2. Fall back to /Applications/Solaro.app (legacy `SOLARO.app` still
//    accepted for installs that haven't been re-bundled yet).
// 3. Then to the user's ~/Applications/ folder.
let candidates: [String] = [
    ProcessInfo.processInfo.environment["SOLARO_APP"] ?? "",
    "/Applications/Solaro.app",
    "/Applications/SOLARO.app",
    "\(NSHomeDirectory())/Applications/Solaro.app",
    "\(NSHomeDirectory())/Applications/SOLARO.app",
].filter { !$0.isEmpty }

let appBundle = candidates.first { FileManager.default.fileExists(atPath: $0) }

guard let appBundle else {
    FileHandle.standardError.write(Data("""
    solaro: cannot find Solaro.app — looked in:
    \(candidates.map { "  - \($0)" }.joined(separator: "\n"))
    Set SOLARO_APP=/path/to/Solaro.app or install via the .dmg.
    """.utf8))
    FileHandle.standardError.write(Data("\n".utf8))
    exit(1)
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
var args = ["-a", appBundle]
if !argPath.isEmpty {
    args.append(argPath)
}
task.arguments = args
do {
    try task.run()
    task.waitUntilExit()
    exit(task.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("solaro: failed to launch \(appBundle): \(error)\n".utf8))
    exit(1)
}

#elseif os(Linux)

// On Linux SOLARO ships as an AppImage. Look in PATH and standard
// locations; honor SOLARO_APPIMAGE env var.
let candidates: [String] = [
    ProcessInfo.processInfo.environment["SOLARO_APPIMAGE"] ?? "",
    "/usr/local/bin/SOLARO.AppImage",
    "/opt/solaro/SOLARO.AppImage",
    "\(NSHomeDirectory())/.local/bin/SOLARO.AppImage",
].filter { !$0.isEmpty }

let appImage = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }

guard let appImage else {
    FileHandle.standardError.write(Data("""
    solaro: cannot find SOLARO.AppImage — looked in:
    \(candidates.map { "  - \($0)" }.joined(separator: "\n"))
    Set SOLARO_APPIMAGE=/path/to/SOLARO.AppImage or install via the .AppImage.
    """.utf8))
    FileHandle.standardError.write(Data("\n".utf8))
    exit(1)
}

let task = Process()
task.executableURL = URL(fileURLWithPath: appImage)
if !argPath.isEmpty {
    task.arguments = [argPath]
}
do {
    try task.run()
    task.waitUntilExit()
    exit(task.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("solaro: failed to launch \(appImage): \(error)\n".utf8))
    exit(1)
}

#else

FileHandle.standardError.write(Data("solaro: launcher only supports macOS and Linux for now.\n".utf8))
exit(1)

#endif
