import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(Windows)
import WinSDK
#endif

/// Detects terminal capabilities at runtime
public struct CapabilityDetector: Sendable {
    /// Detect terminal capabilities using system calls and environment variables
    public static func detect() -> Capabilities {
        let (rows, columns) = detectDimensions()
        let supportsColor = detectColorSupport()
        let supportsTrueColor = detectTrueColorSupport()
        let supportsUnicode = detectUnicodeSupport()
        let isTTY = detectTTY()
        let encoding = detectEncoding()

        return Capabilities(
            rows: rows,
            columns: columns,
            supportsColor: supportsColor,
            supportsTrueColor: supportsTrueColor,
            supportsUnicode: supportsUnicode,
            isTTY: isTTY,
            encoding: encoding
        )
    }

    // MARK: - Private Detection Methods

    /// Detect terminal dimensions using ioctl or environment variables
    private static func detectDimensions() -> (rows: Int, columns: Int) {
        #if os(Windows)
        // Windows has no `ioctl`, and asking the environment first meant the
        // size came from `LINES`/`COLUMNS` — variables nothing on Windows sets
        // — so every terminal was 24x80 and a resize was never noticed
        // (GitLab #699). `GetConsoleScreenBufferInfo` is the real question.
        //
        // The *window* rectangle, not `dwSize`: `dwSize` is the scrollback
        // buffer, which is routinely 9 000 rows tall, and laying a UI out to
        // that is worse than laying it out to a wrong-but-plausible 24.
        let handle = GetStdHandle(STD_OUTPUT_HANDLE)
        if handle != INVALID_HANDLE_VALUE {
            var info = CONSOLE_SCREEN_BUFFER_INFO()
            if GetConsoleScreenBufferInfo(handle, &info) {
                let rows = Int(info.srWindow.Bottom - info.srWindow.Top) + 1
                let columns = Int(info.srWindow.Right - info.srWindow.Left) + 1
                if rows > 0 && columns > 0 {
                    return (rows, columns)
                }
            }
        }
        #else
        // Try ioctl first (most accurate)
        var winsize = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &winsize) == 0 {
            let rows = Int(winsize.ws_row)
            let columns = Int(winsize.ws_col)
            if rows > 0 && columns > 0 {
                return (rows, columns)
            }
        }
        #endif

        // Fallback to environment variables
        if let lines = ProcessInfo.processInfo.environment["LINES"],
           let cols = ProcessInfo.processInfo.environment["COLUMNS"],
           let rows = Int(lines),
           let columns = Int(cols),
           rows > 0 && columns > 0 {
            return (rows, columns)
        }

        // Default fallback
        return (24, 80)
    }

    /// Detect basic color support via TERM environment variable
    private static func detectColorSupport() -> Bool {
        guard let term = ProcessInfo.processInfo.environment["TERM"] else {
            return false
        }

        // Check for color-capable terminals
        let colorTerminals = [
            "xterm-color", "xterm-256color", "screen-256color",
            "tmux-256color", "rxvt-unicode-256color",
            "ansi", "linux", "cygwin", "vt100", "vt220",
            "screen", "tmux"
        ]

        if colorTerminals.contains(term) {
            return true
        }

        // Check for color substring
        if term.contains("color") || term.contains("256") {
            return true
        }

        return false
    }

    /// Detect true color (24-bit RGB) support
    private static func detectTrueColorSupport() -> Bool {
        // Check COLORTERM environment variable
        if let colorTerm = ProcessInfo.processInfo.environment["COLORTERM"] {
            if colorTerm == "truecolor" || colorTerm == "24bit" {
                return true
            }
        }

        // Check TERM for truecolor indicators
        if let term = ProcessInfo.processInfo.environment["TERM"] {
            if term.contains("truecolor") || term.contains("24bit") {
                return true
            }
        }

        // Windows Terminal support
        #if os(Windows)
        if ProcessInfo.processInfo.environment["WT_SESSION"] != nil {
            return true
        }
        #endif

        // iTerm2 support (macOS)
        if let termProgram = ProcessInfo.processInfo.environment["TERM_PROGRAM"] {
            if termProgram == "iTerm.app" {
                return true
            }
        }

        return false
    }

    /// Detect Unicode support
    private static func detectUnicodeSupport() -> Bool {
        // Check encoding
        let encoding = detectEncoding()
        if encoding.lowercased().contains("utf") {
            return true
        }

        // Check LANG environment variable
        if let lang = ProcessInfo.processInfo.environment["LANG"] {
            if lang.lowercased().contains("utf") {
                return true
            }
        }

        // Check LC_ALL
        if let lcAll = ProcessInfo.processInfo.environment["LC_ALL"] {
            if lcAll.lowercased().contains("utf") {
                return true
            }
        }

        // Modern terminals usually support Unicode
        return true
    }

    /// Check if stdout is connected to a TTY
    private static func detectTTY() -> Bool {
        #if !os(Windows)
        return isatty(STDOUT_FILENO) != 0
        #else
        // `TTYDetector` asks `GetFileType(GetStdHandle(…))`, which is the same
        // question `isatty` answers and has worked on Windows all along. The
        // environment sniffing it replaces reported "no terminal" for an
        // interactive `cmd.exe` and "terminal" for a Windows Terminal session
        // with its output piped to a file (GitLab #699).
        return TTYDetector.stdoutIsTTY
        #endif
    }

    /// Detect terminal character encoding
    private static func detectEncoding() -> String {
        // Check LANG first
        if let lang = ProcessInfo.processInfo.environment["LANG"] {
            // LANG is typically in format: "en_US.UTF-8"
            if let encodingPart = lang.split(separator: ".").last {
                return String(encodingPart)
            }
        }

        // Check LC_ALL
        if let lcAll = ProcessInfo.processInfo.environment["LC_ALL"] {
            if let encodingPart = lcAll.split(separator: ".").last {
                return String(encodingPart)
            }
        }

        // Default to UTF-8 (most common)
        return "UTF-8"
    }
}

// MARK: - Platform-Specific Structures

#if !os(Windows)
/// Terminal window size structure (Unix/Linux/macOS)
private struct winsize {
    var ws_row: UInt16 = 0
    var ws_col: UInt16 = 0
    var ws_xpixel: UInt16 = 0
    var ws_ypixel: UInt16 = 0
}

/// ioctl request code for getting window size
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
private let TIOCGWINSZ: UInt = 0x40087468
#else
private let TIOCGWINSZ: UInt = 0x5413
#endif

#endif
