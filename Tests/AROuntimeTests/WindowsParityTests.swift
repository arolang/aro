// ============================================================
// WindowsParityTests.swift
// ARO Runtime — the Windows branches, asserted from every platform
// GitLab #682, #684, #685
// ============================================================
//
// Windows is neither built nor tested in any CI pipeline (#686), so a Windows
// branch is written once and then never executed again. What can be tested
// everywhere is the *decision* each branch makes — the shell to launch, whether
// a store opts in to persistence — as long as that decision is a pure function
// rather than a `#if` wrapped around a side effect.
//
// These tests assert those functions. They do not — cannot, from macOS or Linux
// — assert that `cmd.exe` launches or that `SetConsoleCtrlHandler` fires. That
// is stated plainly rather than implied by a green suite.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Windows parity (#682, #684, #685)")
struct WindowsParityTests {

    // MARK: - #682: the shell is not always /bin/sh

    @Test("The default shell is the host's, not a hardcoded /bin/sh")
    func defaultShellIsPlatformCorrect() {
        let shell = ExecConfig.defaultShell
        #if os(Windows)
        // `%COMSPEC%` when set, cmd.exe otherwise — never a POSIX path.
        #expect(shell.lowercased().contains("cmd.exe") || !shell.hasPrefix("/"))
        #else
        #expect(shell == "/bin/sh")
        #endif
    }

    @Test("The shell's command flag matches the shell")
    func commandFlagMatchesTheShell() {
        // `sh -c` and `cmd /c` take a command string; pairing one shell with
        // the other's flag runs nothing and reports success.
        #if os(Windows)
        #expect(ExecConfig.shellCommandFlag == "/c")
        #else
        #expect(ExecConfig.shellCommandFlag == "-c")
        #endif
    }

    @Test("A config with no shell of its own takes the platform default")
    func configDefaultsToPlatformShell() {
        #expect(ExecConfig(command: "echo hi").shell == ExecConfig.defaultShell)
    }

    @Test("An explicit shell still wins")
    func explicitShellIsHonoured() {
        // `Exec … with { shell: "/bin/bash" }` is a documented override and
        // must not be overwritten by the platform default.
        #expect(ExecConfig(command: "echo hi", shell: "/bin/bash").shell == "/bin/bash")
    }

    // MARK: - #684: a store is read-only until it says otherwise

    @Test("A store with no marker is read-only")
    func storeWithoutMarkerIsReadOnly() {
        // The default has to be read-only, because that is the half of the
        // contract a mistake destroys data in.
        #expect(StoreFileLoader.declaresWindowsWritability("- name: Alice\n") == false)
    }

    @Test("The marker opts a store in")
    func markerOptsIn() {
        #expect(StoreFileLoader.declaresWindowsWritability("# aro-store: writable\n- name: Alice\n"))
    }

    @Test("The marker is case- and space-insensitive")
    func markerIsForgiving() {
        #expect(StoreFileLoader.declaresWindowsWritability("#aro-store:writable\n"))
        #expect(StoreFileLoader.declaresWindowsWritability("#   ARO-Store:   Writable   \n"))
    }

    @Test("Other comments above the marker do not hide it")
    func markerSurvivesACommentBlock() {
        let content = """
            # Users seeded at startup.
            # Owner: platform team
            # aro-store: writable
            - name: Alice
            """
        #expect(StoreFileLoader.declaresWindowsWritability(content))
    }

    @Test("A marker below the data is not a header")
    func markerAfterDataIsIgnored() {
        // Otherwise a `.store` written by the application could opt itself in,
        // which is exactly the escalation the permission gate exists to stop.
        let content = """
            - name: Alice
            # aro-store: writable
            """
        #expect(StoreFileLoader.declaresWindowsWritability(content) == false)
    }

    @Test("A directive that is not the marker leaves the store read-only")
    func unrelatedDirectivesAreIgnored() {
        #expect(StoreFileLoader.declaresWindowsWritability("# aro-store: read-only\n") == false)
        #expect(StoreFileLoader.declaresWindowsWritability("# writable\n") == false)
        #expect(StoreFileLoader.declaresWindowsWritability("# aro-store: writable-ish\n") == false)
    }

    @Test("An empty file is read-only")
    func emptyFileIsReadOnly() {
        #expect(StoreFileLoader.declaresWindowsWritability("") == false)
    }

    // MARK: - #685: something is installed, on every platform

    @Test("Installing a shutdown handler does not crash and is reachable")
    func shutdownHandlerIsInstallable() {
        // `ShutdownSignals.install` replaces three unguarded `signal()` pairs.
        // What is assertable everywhere is that the indirection works — that
        // the stored handler is the one `invoke` reaches. Whether Windows's
        // console subsystem calls it is not observable from here.
        AROShutdownProbe.fired = false
        ShutdownSignals.install { AROShutdownProbe.fired = true }
        ShutdownSignals.invokeForTesting()
        #expect(AROShutdownProbe.fired)
    }
}

/// A non-capturing landing pad, because a shutdown handler becomes a C
/// function pointer and so cannot close over a local.
enum AROShutdownProbe {
    nonisolated(unsafe) static var fired = false
}
