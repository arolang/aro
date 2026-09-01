import Foundation

/// Environment for spawning a foreign toolchain (`cargo`, `rustc`, `swift build`).
///
/// `aro` links against a specific LLVM, so installations routinely point
/// `DYLD_LIBRARY_PATH` at it — our own CI does, and so does anyone following
/// the Homebrew LLVM instructions. Child processes inherit that variable, and
/// on macOS it forces *every* dylib lookup by leaf name, including a lookup we
/// were never meant to answer: `rustc` ships its own `libLLVM.dylib`, finds
/// ours first, and dies before it compiles anything.
///
///     dyld: Symbol not found: __ZN4llvm10DILocation7getImplERNS_11LLVMContextE…
///       Referenced from: …/librustc_driver-<hash>.dylib
///       Expected in:     …/llvm@20/lib/libLLVM.dylib
///
/// It surfaces as `SIGSEGV`/`SIGABRT` from cargo's target-info probe, which
/// runs on every invocation — so a pre-built plugin does not avoid it.
///
/// Only the `DYLD_*` family is stripped. Linux's `LD_LIBRARY_PATH` is left
/// alone deliberately: `rustc` there resolves its LLVM without consulting it,
/// and the Linux CI job sets it to reach `libLLVM-20` for other tools.
public enum ToolchainEnvironment {
    /// Variables that steer macOS dylib resolution. `DYLD_INSERT_LIBRARIES` is
    /// included for completeness — nothing in ARO sets it, but anything that
    /// injects a library into us has no business injecting it into a compiler.
    private static let dynamicLinkerOverrides = [
        "DYLD_LIBRARY_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_INSERT_LIBRARIES",
    ]

    /// The current environment with our dynamic-linker overrides removed.
    ///
    /// A no-op on Linux, where these variables are unused.
    public static func forExternalToolchain() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for name in dynamicLinkerOverrides {
            environment.removeValue(forKey: name)
        }
        return environment
    }
}
