// ============================================================
// DlopenProbe.swift
// ARO Runtime - Safe dlopen probe for Linux
// ============================================================
//
// On Linux, Swift-built dynamic libraries can crash the dynamic linker
// (SIGSEGV in ld-linux due to TLS exhaustion) when dlopen'd into a
// process that already has the Swift runtime loaded.
//
// This module provides a fork-based probe that tests dlopen in a child
// process first, so a crash doesn't take out the host process.

#if canImport(Glibc)
import Glibc
#endif

/// Fork a child process and attempt dlopen there.
/// Returns true if the child exited normally (dlopen succeeded or returned NULL),
/// false if the child was killed by a signal (SIGSEGV, etc.).
/// On non-Linux platforms, always returns true.
func safeDlopenProbe(_ path: String) -> Bool {
    #if os(Linux) && canImport(Glibc)
    let pid = fork()
    if pid == 0 {
        // Child — try the dlopen, then exit.
        // Close stdout/stderr file descriptors to avoid mixing output.
        close(STDOUT_FILENO)
        close(STDERR_FILENO)
        _ = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        _exit(0)  // Success — even if dlopen returned NULL, it didn't crash.
    }
    guard pid > 0 else {
        // fork failed — assume safe and try anyway
        return true
    }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    // Child exited normally (low 7 bits == 0) means no signal killed it.
    return (status & 0x7F) == 0
    #else
    _ = path
    return true
    #endif
}
