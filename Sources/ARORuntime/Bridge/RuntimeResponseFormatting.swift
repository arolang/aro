// ============================================================
// RuntimeResponseFormatting.swift
// ARORuntime - C-callable response/error formatting for compiled binaries
// ============================================================
//
// Owns the C-ABI bridge for surfacing a context's outcome to the CLI:
// printing the response, checking for an execution error, and printing the
// error in interpreter-compatible form (plus the throw-message parser helper).
// Extracted from RuntimeBridge.swift (issue #313) — pure move, no behaviour change.

import Foundation
import AROParser

/// Print the response from the context (for compiled binaries)
/// - Parameter contextPtr: Context handle
@_cdecl("aro_context_print_response")
public func aro_context_print_response(_ contextPtr: UnsafeMutableRawPointer?) {
    guard let ptr = contextPtr else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    if let response = contextHandle.context.getResponse() {
        // Don't print lifecycle exit response (e.g., "Return ... for the <application>")
        if response.reason != "application" {
            // Use human-readable format for CLI output
            print(response.format(for: .human))
        }
    }
}

/// Check if the context has an execution error
/// - Parameter contextPtr: Context handle
/// - Returns: 1 if there's an error, 0 otherwise
@_cdecl("aro_context_has_error")
public func aro_context_has_error(_ contextPtr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = contextPtr else { return 0 }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    return contextHandle.context.hasExecutionError() ? 1 : 0
}

/// Force every deferred action still outstanding on this context (ARO-0088 §3).
///
/// Emitted by the code generator at each feature set's exit, before the result
/// is loaded. Deferred work that nobody read must still run — and if it failed,
/// the failure has to reach the context's error slot here, because the
/// per-statement `aro_context_has_error` check ran while the action was still
/// in flight and saw nothing.
/// - Parameter contextPtr: Context handle
@_cdecl("aro_context_drain_deferred")
public func aro_context_drain_deferred(_ contextPtr: UnsafeMutableRawPointer?) {
    guard let ptr = contextPtr else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    guard let runtime = contextHandle.context as? RuntimeContext else { return }

    let drainError = runtime.drainPendingFutures()
    if let observed = runtime.takeDeferredFailure() {
        runtime.setExecutionError(observed)
    } else if let drainError {
        runtime.setExecutionError(drainError)
    }
}

/// Print the execution error from the context (for compiled binaries)
/// - Parameter contextPtr: Context handle
@_cdecl("aro_context_print_error")
public func aro_context_print_error(_ contextPtr: UnsafeMutableRawPointer?) {
    guard let ptr = contextPtr else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    if let error = contextHandle.context.getExecutionError() {
        // Format error message similar to interpreter
        if let actionError = error as? ActionError {
            switch actionError {
            case .thrown(let type, let reason, _):
                // Match interpreter format: "Runtime error: Runtime Error: Cannot throw the <Type> for the <reason> when <condition>."
                print("Runtime error: Runtime Error: Cannot throw the \(type) for the \(reason) when <condition>.")
            case .runtimeError(let message):
                // The error message might be from ActionError.thrown that was stringified
                // Format: "<type> in <context>: <reason>"
                // We need to convert it to: "Runtime Error: Cannot throw the <type> for the <reason> when <condition>."
                if let match = parseThrowErrorMessage(message) {
                    print("Runtime error: Runtime Error: Cannot throw the \(match.type) for the \(match.reason) when <condition>.")
                } else {
                    print("Runtime error: \(message)")
                }
            default:
                print("Runtime error: \(error.localizedDescription)")
            }
        } else {
            print("Runtime error: \(error.localizedDescription)")
        }
    }
}

/// Parse a throw error message in format "<type> in <context>: <reason>"
/// Returns the type and reason components, or nil if format doesn't match
private func parseThrowErrorMessage(_ message: String) -> (type: String, reason: String)? {
    // Pattern: "<type> in <context>: <reason>"
    // Example: "InputError in Application-Start: negative-value"
    guard let inRange = message.range(of: " in "),
          let colonRange = message.range(of: ": ", range: inRange.upperBound..<message.endIndex) else {
        return nil
    }

    let type = String(message[..<inRange.lowerBound])
    let reason = String(message[colonRange.upperBound...])

    return (type: type, reason: reason)
}
