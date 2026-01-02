// ============================================================
// Version.swift
// ARO Version Information
// ============================================================
// This file provides version and build information for the ARO CLI

import Foundation

public enum AROVersion {
    /// Get the version from git describe or fallback to unknown
    public static let version: String = {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "git describe --tags --always --dirty 2>/dev/null || echo 'unknown'"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            if let data = try? pipe.fileHandleForReading.readToEnd(),
               let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {}

        return "unknown"
    }()

    /// Get the short commit hash
    public static let commit: String = {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "git rev-parse --short HEAD 2>/dev/null || echo 'unknown'"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            if let data = try? pipe.fileHandleForReading.readToEnd(),
               let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {}

        return "unknown"
    }()

    /// Build date in ISO 8601 format
    public static let buildDate: String = {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }()

    /// Whether this is a release build
    public static let isRelease: Bool = {
        !version.contains("-dirty") && !version.hasPrefix("unknown")
    }()

    /// Full version string with commit and build date
    public static var fullVersion: String {
        "\(version) (\(commit)) built on \(buildDate)"
    }

    /// Short version string (just the version)
    public static var shortVersion: String {
        version
    }
}
