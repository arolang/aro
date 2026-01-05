#if os(Windows)
import WinSDK
#elseif os(Linux)
import Glibc
#else
import Darwin
#endif

/// Detects whether stdout, stderr, and stdin are connected to a TTY.
/// Evaluated once at startup and cached for performance.
///
/// Uses platform-specific functions:
/// - POSIX (macOS, Linux): `isatty(STDOUT_FILENO)`
/// - Windows: `GetFileType(GetStdHandle(...))`
public struct TTYDetector {
    /// True if stdout is connected to a terminal/console
    public static let stdoutIsTTY: Bool = {
        #if os(Windows)
        return isWindowsConsoleTTY(STD_OUTPUT_HANDLE)
        #else
        return isatty(STDOUT_FILENO) != 0
        #endif
    }()

    /// True if stderr is connected to a terminal/console
    public static let stderrIsTTY: Bool = {
        #if os(Windows)
        return isWindowsConsoleTTY(STD_ERROR_HANDLE)
        #else
        return isatty(STDERR_FILENO) != 0
        #endif
    }()

    /// True if stdin is connected to a terminal/console
    public static let stdinIsTTY: Bool = {
        #if os(Windows)
        return isWindowsConsoleTTY(STD_INPUT_HANDLE)
        #else
        return isatty(STDIN_FILENO) != 0
        #endif
    }()

    /// Convenience: true if both stdout and stderr are TTY (fully interactive)
    public static let isInteractive: Bool = {
        return stdoutIsTTY && stderrIsTTY
    }()

    #if os(Windows)
    /// Check if a Windows standard handle is connected to a console/TTY
    private static func isWindowsConsoleTTY(_ handleType: DWORD) -> Bool {
        guard let handle = GetStdHandle(handleType), handle != INVALID_HANDLE_VALUE else {
            return false
        }
        let fileType = GetFileType(handle)
        return fileType == FILE_TYPE_CHAR
    }
    #endif
}
