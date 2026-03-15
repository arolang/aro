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

        // Set raw mode (keep ISIG so Ctrl-C still generates SIGINT)
        var raw = old
        #if canImport(Darwin)
        cfmakeraw(&raw)
        raw.c_lflag |= tcflag_t(ISIG)  // re-enable signal generation (Ctrl-C → SIGINT)
        #else
        raw.c_iflag &= ~(tcflag_t(IGNBRK) | tcflag_t(BRKINT) | tcflag_t(PARMRK) |
                         tcflag_t(ISTRIP) | tcflag_t(INLCR)  | tcflag_t(IGNCR)  |
                         tcflag_t(ICRNL)  | tcflag_t(IXON))
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ECHONL) | tcflag_t(ICANON) |
                                          tcflag_t(IEXTEN))  // ISIG intentionally kept
        raw.c_cflag &= ~(tcflag_t(CSIZE) | tcflag_t(PARENB))
        raw.c_cflag |= tcflag_t(CS8)
        #endif
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        // Enable bracketed paste mode: terminal wraps paste with ESC[200~ … ESC[201~
        // so we can strip the markers and pass through the content cleanly.
        writeRaw("\u{1B}[?2004h")

        // Byte-level state machine — handles normal keys, arrow keys, and bracketed paste.
        // emitKey uses publishAndWait so each handler completes before the next key fires;
        // this prevents paste-burst race conditions where concurrent handlers all read stale state.
        var inPaste = false

        while isRunning {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(STDIN_FILENO, &buf, 256)
            if n <= 0 || !isRunning { break }

            var i = 0
            while i < n {
                // Detect ESC[200~ (paste start) or ESC[201~ (paste end) — 6 bytes each
                if buf[i] == 27 && i + 5 < n && buf[i+1] == 91 && buf[i+2] == 50 && buf[i+3] == 48 {
                    if buf[i+4] == 48 && buf[i+5] == 126 {   // ESC[200~
                        inPaste = true; i += 6; continue
                    }
                    if buf[i+4] == 49 && buf[i+5] == 126 {   // ESC[201~
                        inPaste = false; i += 6; continue
                    }
                }

                if buf[i] == 27 && !inPaste {
                    // Arrow keys: ESC [ A/B/C/D (3 bytes)
                    if i + 2 < n && buf[i+1] == 91 {
                        switch buf[i+2] {
                        case 65: await emitKey("up");    i += 3
                        case 66: await emitKey("down");  i += 3
                        case 67: await emitKey("right"); i += 3
                        case 68: await emitKey("left");  i += 3
                        default: await emitKey("escape"); i += 1
                        }
                        continue
                    }
                    await emitKey("escape"); i += 1; continue
                }

                // Printable byte — applies both in normal mode and inside a paste
                await emitByte(buf[i])
                i += 1
            }
        }

        writeRaw("\u{1B}[?2004l")  // Disable bracketed paste mode
        restoreTerminal()
        #endif
    }

    private func emitByte(_ b: UInt8) async {
        switch b {
        case 9:         await emitKey("tab")
        case 10, 13:    await emitKey("enter")
        case 127:       await emitKey("backspace")
        case 32..<127:  await emitKey(String(UnicodeScalar(b)))
        default:        break   // non-printable control byte — ignore
        }
    }

    /// Publish a key event and wait for the handler to finish before returning.
    /// Using publishAndWait (not fire-and-forget publish) ensures that paste bursts
    /// are serialised: each character's handler reads the state written by the previous
    /// character, so rapid paste never overwrites earlier characters.
    ///
    /// Two events are published:
    /// 1. KeyPressEvent — consumed by interpreter-mode KeyPress Handler feature sets
    ///    (registered via ExecutionEngine.registerKeyPressHandlers)
    /// 2. DomainEvent("KeyPress") — consumed by binary-mode compiled handlers
    ///    (registered via aro_runtime_register_handler("KeyPress", ...))
    /// No double-firing in interpreter mode: KeyPress Handler is excluded from
    /// registerDomainEventHandlers (ExecutionEngine.swift line ~369), and
    /// _compiledHandlers["KeyPress"] is empty in interpreter mode.
    private func emitKey(_ key: String) async {
        await eventBus.publishAndWait(KeyPressEvent(key: key))
        // Co-publish DomainEvent("KeyPress") for binary mode compiled handlers.
        await eventBus.publishAndWait(DomainEvent(eventType: "KeyPress", payload: ["key": key]))
    }

    private func writeRaw(_ string: String) {
        if let data = string.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
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

}
