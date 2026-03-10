// ============================================================
// KeyboardService.swift
// ARO Runtime - Raw keyboard input service
// ============================================================

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Safety net: restores terminal on unexpected exit
// nonisolated(unsafe): protected by the atexit single-exit guarantee (only written from readLoop)
private nonisolated(unsafe) var _savedTermiosForAtExit: termios? = nil

/// Service that reads raw keyboard input and publishes KeyPressEvents
public final class KeyboardService: @unchecked Sendable {
    private let eventBus: EventBus
    private var readTask: Task<Void, Never>?
    private var isRunning = false
    private var savedTermios: termios? = nil

    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    /// Start listening for keyboard input. No-op when stdin is not a TTY.
    public func startListening() async {
        #if os(Windows)
        return  // Keyboard raw mode not supported on Windows
        #else
        guard isatty(STDIN_FILENO) != 0 else { return }
        guard !isRunning else { return }
        isRunning = true

        // Register as active event source so Keepalive stays alive
        await EventBus.shared.registerEventSource()

        readTask = Task.detached { [weak self] in
            await self?.readLoop()
        }
        #endif
    }

    /// Stop keyboard listening and restore terminal state
    public func stop() async {
        isRunning = false
        readTask?.cancel()
        restoreTerminal()
        await EventBus.shared.unregisterEventSource()
    }

    // MARK: - Private

    private func readLoop() async {
        #if !os(Windows)
        var old = termios()
        tcgetattr(STDIN_FILENO, &old)
        savedTermios = old
        _savedTermiosForAtExit = old

        // Install atexit safety net to restore terminal if process exits unexpectedly
        atexit {
            if var saved = _savedTermiosForAtExit {
                tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
            }
        }

        // Set raw mode
        var raw = old
        #if canImport(Darwin)
        cfmakeraw(&raw)
        #else
        raw.c_iflag &= ~(tcflag_t(IGNBRK) | tcflag_t(BRKINT) | tcflag_t(PARMRK) |
                         tcflag_t(ISTRIP) | tcflag_t(INLCR)  | tcflag_t(IGNCR)  |
                         tcflag_t(ICRNL)  | tcflag_t(IXON))
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ECHONL) | tcflag_t(ICANON) |
                         tcflag_t(ISIG)  | tcflag_t(IEXTEN))
        raw.c_cflag &= ~(tcflag_t(CSIZE) | tcflag_t(PARENB))
        raw.c_cflag |= tcflag_t(CS8)
        #endif
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        // Read loop
        while isRunning {
            var buf = [UInt8](repeating: 0, count: 6)
            let n = read(STDIN_FILENO, &buf, 6)
            if n <= 0 || !isRunning { break }
            let key = parseKey(buf, count: n)
            let event = KeyPressEvent(key: key)
            eventBus.publish(event)
        }

        restoreTerminal()
        #endif
    }

    private func restoreTerminal() {
        #if !os(Windows)
        if var saved = savedTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
            savedTermios = nil
            _savedTermiosForAtExit = nil
        }
        #endif
    }

    /// Map raw byte sequences to key names
    private func parseKey(_ buf: [UInt8], count: Int) -> String {
        switch (count, buf[0]) {
        case (1, 9):            // HT → Tab
            return "tab"
        case (1, 13), (1, 10):  // CR / LF → Enter
            return "enter"
        case (1, 27):           // lone ESC
            return "escape"
        case (1, 127):          // DEL → Backspace
            return "backspace"
        case (1, let c) where c >= 32 && c < 127:
            return String(UnicodeScalar(c))
        case (3, 27) where buf[1] == 91:  // ESC [ X
            switch buf[2] {
            case 65: return "up"
            case 66: return "down"
            case 67: return "right"
            case 68: return "left"
            default: return "escape"
            }
        default:
            return "unknown"
        }
    }
}
