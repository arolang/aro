// ============================================================
// RuntimeEnvironment.swift
// ARO Runtime — process environment, read once
// GitLab #705
// ============================================================
//
// `ProcessInfo.processInfo.environment` is not a lookup. It builds a fresh
// `[String: String]` from `environ` on every access, on both Darwin and Linux,
// so a subscript in a hot path copies the whole environment to answer one
// question. The runtime was doing that per statement (the deferral policy) and
// per event (the debug logging), which is tens of microseconds of pure copying
// at execution rate.
//
// These are switches set before the process starts. Nothing in ARO changes
// them at run time, and a program that could would have bigger problems than
// this cache — so they are read once, lazily, on first use.

import Foundation

public enum RuntimeEnvironment {

    /// `ARO_DEBUG` — extra diagnostic logging on the event paths.
    public static let isDebug: Bool =
        ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil

    /// Read a variable that genuinely may change, or that is read once anyway.
    ///
    /// Here so a caller does not have to decide between this type and
    /// `ProcessInfo` — and so `grep ProcessInfo.*environment` keeps finding
    /// only the cold paths.
    public static func value(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }
}
