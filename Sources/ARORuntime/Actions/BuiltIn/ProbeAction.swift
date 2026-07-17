// ============================================================
// ProbeAction.swift
// ARO Runtime - HTTP Reachability Probe Action
// ============================================================

import Foundation
import AROParser

/// Checks whether a target is reachable without halting on failure.
///
/// `Probe` is the counterpart to `Request` for the cases where the
/// unreachable answer IS the success answer — uptime monitors,
/// health-checks before fail-over, reachability probes. Where
/// `Request` means "I depend on this target — halt if it's gone"
/// (ARO-0006: code is the error message), `Probe` never throws on
/// DNS, connect, or TLS failure; the outcome lands in the result
/// envelope instead:
///
/// | Field       | Reachable          | Unreachable |
/// |-------------|--------------------|-------------|
/// | `reachable` | `true`             | `false`     |
/// | `status`    | HTTP status code   | absent      |
/// | `latency`   | milliseconds       | absent      |
/// | `reason`    | absent             | failure description |
///
/// Any HTTP status — including 4xx/5xx — counts as reachable: the
/// host answered.
///
/// ## Syntax
/// ```aro
/// (* Simple reachability check — aggressive 2s default timeout *)
/// Probe the <reachability> from <target>.
/// Extract the <reachable> from the <reachability: reachable>.
///
/// (* Custom timeout (seconds) *)
/// Probe the <reachability> from <target> with { timeout: 5 }.
/// ```
///
/// ## Example
/// ```aro
/// (Check Upstream: Health Monitor) {
///     Probe the <reachability> from "https://api.example.com/health".
///     Extract the <reachable> from the <reachability: reachable>.
///     When <reachable> is false: Emit an <UpstreamDown: event> with <reachability>.
///     Return an <OK: status> with <reachability>.
/// }
/// ```
public struct ProbeAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["probe"]
    public static let validPrepositions: Set<Preposition> = [.from, .with]

    /// Health-checks and monitors want a fast verdict, not a data
    /// fetch — time out aggressively unless overridden via
    /// `with { timeout: … }`.
    public static let defaultTimeout: TimeInterval = 2.0

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        #if !os(Windows)
        let urlClient: URLSessionHTTPClient
        if let existingClient = context.service(URLSessionHTTPClient.self) {
            urlClient = existingClient
        } else {
            let newClient = URLSessionHTTPClient()
            context.register(newClient)
            urlClient = newClient
        }

        let config = resolveWithConfig(context)
        let timeout = extractTimeout(from: config) ?? Self.defaultTimeout

        // Determine URL — same resolution order as RequestAction.
        let url: String
        if context.exists(object.base) {
            url = try context.resolveWithSpecifiers(object.base, specifiers: object.specifiers)
        } else if config.isEmpty, let literalUrl = context.resolveAny("_literal_") as? String,
                  literalUrl.hasPrefix("http") {
            url = literalUrl
        } else {
            url = object.base
        }

        // A malformed URL is a programming error, not an unreachable
        // target — halt loudly, exactly like Request would.
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw ActionError.invalidURL(url)
        }

        // The probe itself never throws: DNS failure, connection
        // refused, TLS errors, and timeouts are all valid answers.
        let startedAt = DispatchTime.now()
        do {
            let response = try await urlClient.get(
                url: url, headers: [:], timeout: timeout
            )
            let elapsedMs = Double(
                DispatchTime.now().uptimeNanoseconds
                    - startedAt.uptimeNanoseconds
            ) / 1_000_000.0
            return [
                "target": url,
                "reachable": true,
                "status": response.statusCode,
                "latency": elapsedMs,
            ] as [String: any Sendable]
        } catch {
            return [
                "target": url,
                "reachable": false,
                "reason": error.localizedDescription,
            ] as [String: any Sendable]
        }
        #else
        throw ActionError.unsupportedPlatform("HTTP client")
        #endif
    }

    // MARK: - Private Helpers

    private func extractTimeout(from config: [String: any Sendable]) -> TimeInterval? {
        if let timeout = config["timeout"] as? Int {
            return TimeInterval(timeout)
        }
        if let timeout = config["timeout"] as? Double {
            return timeout
        }
        return nil
    }
}
