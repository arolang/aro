import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Handles keyboard input for terminal interactions
public struct InputHandler: Sendable {
    public init() {}

    /// Read a line of text from stdin
    /// - Parameters:
    ///   - prompt: Prompt message to display
    ///   - hidden: Hide input (for passwords)
    /// - Returns: User input string
    public func readLine(prompt: String, hidden: Bool) async -> String {
        // Display prompt
        print(prompt, terminator: "")
        flushStdout()

        if hidden {
            // For hidden input, we need to disable echo
            return await readHiddenInput()
        } else {
            // Normal input
            return Swift.readLine() ?? ""
        }
    }

    /// Display interactive selection menu
    /// - Parameters:
    ///   - options: Available options
    ///   - message: Prompt message
    ///   - multiSelect: Allow multiple selections
    /// - Returns: Selected option(s)
    public func selectMenu(options: [String], message: String, multiSelect: Bool) async -> [String] {
        // Simple implementation for now - just number the options
        print(message)
        for (index, option) in options.enumerated() {
            print("  \(index + 1). \(option)")
        }

        print("Enter selection (number): ", terminator: "")
        flushStdout()

        if let input = Swift.readLine(),
           let selected = Int(input),
           selected > 0 && selected <= options.count {
            return [options[selected - 1]]
        }

        return []
    }

    // MARK: - Private Methods

    /// Read input with echo disabled (for passwords)
    private func readHiddenInput() async -> String {
        #if !os(Windows)
        var oldTermios = termios()
        var newTermios = termios()

        // Get current terminal settings
        tcgetattr(STDIN_FILENO, &oldTermios)
        newTermios = oldTermios

        // Disable echo
        newTermios.c_lflag &= ~tcflag_t(ECHO)

        // Set new terminal settings
        tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)

        // Read input
        let input = Swift.readLine() ?? ""

        // Restore original terminal settings
        tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)

        // Print newline (since it wasn't echoed)
        print("")

        return input
        #else
        // Windows: just use regular readLine for now
        // TODO: Implement Windows-specific hidden input
        return Swift.readLine() ?? ""
        #endif
    }

    /// Flush stdout
    private func flushStdout() {
        // fflush(nil) flushes all open output streams; avoids referencing the C global 'stdout'
        #if canImport(Darwin)
        Darwin.fflush(nil)
        #elseif canImport(Glibc)
        Glibc.fflush(nil)
        #endif
    }
}
