#if os(Windows)
import ucrt
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
/// - Windows: `_isatty(_fileno(stdout))`
public struct TTYDetector {
    /// True if stdout is connected to a terminal/console
    public static let stdoutIsTTY: Bool = {
        #if os(Windows)
        return _isatty(_fileno(stdout)) != 0
        #else
        return isatty(STDOUT_FILENO) != 0
        #endif
    }()

    /// True if stderr is connected to a terminal/console
    public static let stderrIsTTY: Bool = {
        #if os(Windows)
        return _isatty(_fileno(stderr)) != 0
        #else
        return isatty(STDERR_FILENO) != 0
        #endif
    }()

    /// True if stdin is connected to a terminal/console
    public static let stdinIsTTY: Bool = {
        #if os(Windows)
        return _isatty(_fileno(stdin)) != 0
        #else
        return isatty(STDIN_FILENO) != 0
        #endif
    }()

    /// Convenience: true if both stdout and stderr are TTY (fully interactive)
    public static let isInteractive: Bool = {
        return stdoutIsTTY && stderrIsTTY
    }()
}
