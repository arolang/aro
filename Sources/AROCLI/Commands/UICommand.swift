// ============================================================
// UICommand.swift
// AROCLI - Open Solaro desktop app at a project path
// ============================================================

import ArgumentParser
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Pure helpers for SOLARO launcher discovery — extracted so the resolution
/// logic can be unit-tested without spawning `/usr/bin/open`.
enum UILauncher {
    /// Ordered list of macOS bundle candidates given an environment snapshot
    /// and a home directory. Empty `SOLARO_APP` entries are filtered out.
    static func macCandidates(env: [String: String], home: String) -> [String] {
        // `Solaro.app` is the new bundle name; `SOLARO.app` stays in
        // the candidate list so installs from before the rename still
        // launch from `aro ui`.
        return [
            env["SOLARO_APP"] ?? "",
            "/Applications/Solaro.app",
            "/Applications/SOLARO.app",
            "\(home)/Applications/Solaro.app",
            "\(home)/Applications/SOLARO.app",
        ].filter { !$0.isEmpty }
    }

    /// Ordered list of Linux AppImage candidates.
    static func linuxCandidates(env: [String: String], home: String) -> [String] {
        return [
            env["SOLARO_APPIMAGE"] ?? "",
            "/usr/local/bin/SOLARO.AppImage",
            "/opt/solaro/SOLARO.AppImage",
            "\(home)/.local/bin/SOLARO.AppImage",
        ].filter { !$0.isEmpty }
    }

    /// Resolves a user-supplied path argument: `.` becomes the supplied
    /// current directory; everything else passes through; `nil` stays empty.
    static func resolveArgPath(_ raw: String?, cwd: String) -> String {
        guard let raw else { return "" }
        return raw == "." ? cwd : raw
    }
}

struct UICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Open Solaro (ARO desktop UI) at a project path",
        discussion: """
            Locates the Solaro desktop app and opens it, optionally with a
            project directory loaded. Mirrors the standalone `solaro`
            launcher so terminal users can stay on `aro` for everything.

            Examples:
              aro ui                # Open Solaro with no project
              aro ui .              # Open Solaro with the current directory
              aro ui ./Examples/HelloWorld

            Discovery order on macOS:
              1. $SOLARO_APP
              2. /Applications/Solaro.app  (legacy SOLARO.app accepted)
              3. ~/Applications/Solaro.app (legacy SOLARO.app accepted)

            Discovery order on Linux:
              1. $SOLARO_APPIMAGE
              2. /usr/local/bin/SOLARO.AppImage
              3. /opt/solaro/SOLARO.AppImage
              4. ~/.local/bin/SOLARO.AppImage
            """
    )

    @Argument(help: "Project directory to open (use '.' for current directory)")
    var path: String?

    func run() throws {
        let argPath = UILauncher.resolveArgPath(
            path,
            cwd: FileManager.default.currentDirectoryPath
        )

        #if os(macOS)
        let candidates = UILauncher.macCandidates(
            env: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory()
        )

        guard let appBundle = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            FileHandle.standardError.write(Data("""
            aro ui: cannot find Solaro.app — looked in:
            \(candidates.map { "  - \($0)" }.joined(separator: "\n"))
            Set SOLARO_APP=/path/to/Solaro.app or install via the .dmg.

            """.utf8))
            throw ExitCode.failure
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
            if task.terminationStatus != 0 {
                throw ExitCode(task.terminationStatus)
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            FileHandle.standardError.write(Data("aro ui: failed to launch \(appBundle): \(error)\n".utf8))
            throw ExitCode.failure
        }

        #elseif os(Linux)
        let candidates = UILauncher.linuxCandidates(
            env: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory()
        )

        guard let appImage = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            FileHandle.standardError.write(Data("""
            aro ui: cannot find SOLARO.AppImage — looked in:
            \(candidates.map { "  - \($0)" }.joined(separator: "\n"))
            Set SOLARO_APPIMAGE=/path/to/SOLARO.AppImage or install via the .AppImage.

            """.utf8))
            throw ExitCode.failure
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: appImage)
        if !argPath.isEmpty {
            task.arguments = [argPath]
        }
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                throw ExitCode(task.terminationStatus)
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            FileHandle.standardError.write(Data("aro ui: failed to launch \(appImage): \(error)\n".utf8))
            throw ExitCode.failure
        }

        #else
        FileHandle.standardError.write(Data("aro ui: Solaro is only available on macOS and Linux.\n".utf8))
        throw ExitCode.failure
        #endif
    }
}
