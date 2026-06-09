// ============================================================
// MetricsClient.swift
// SOLARO — consumes the aro runtime's metrics push socket
// ============================================================
//
// Connects to `$TMPDIR/aro-metrics-<pid>.sock` after SOLARO spawns
// `aro run`, reads newline-delimited JSON snapshots, decodes them
// into `MetricsSnapshot` values that the SwiftUI panel observes.
//
// Lifecycle:
//   • call `connect(pid:)` once the aro subprocess is up
//   • the panel renders `latest` and `connectionState` reactively
//   • call `disconnect()` when the process exits / SOLARO quits
//
// The aro process opens the socket inside RunCommand.run() before
// the application starts, so a tiny retry loop is enough to ride
// out the race between spawn and bind.

import Foundation
import SwiftUI

#if canImport(Darwin)
import Darwin
#endif

/// One feature-set row in a metrics snapshot — mirrors the wire
/// shape emitted by `MetricsSocketServer` in ARORuntime.
struct FeatureSetMetric: Decodable, Identifiable, Equatable {
    let name: String
    let businessActivity: String
    let count: Int
    let successes: Int
    let failures: Int
    let totalMs: Double
    let minMs: Double
    let maxMs: Double
    let avgMs: Double
    let successRate: Double

    var id: String { name }
}

struct ProcessMetricsView: Decodable, Equatable {
    let cpuUserSec: Double
    let cpuSystemSec: Double
    let virtualMB: Double
    let residentMB: Double
    let openFDs: Int

    var cpuTotalSec: Double { cpuUserSec + cpuSystemSec }
}

struct MetricsSnapshot: Decodable, Equatable {
    let kind: String
    let collectedAt: String
    let uptimeSec: Double
    let totalExecutions: Int
    let totalSuccesses: Int
    let totalFailures: Int
    let featureSets: [FeatureSetMetric]
    let process: ProcessMetricsView

    var successRate: Double {
        totalExecutions > 0
            ? Double(totalSuccesses) / Double(totalExecutions) * 100
            : 0
    }
}

@Observable
final class MetricsClient: @unchecked Sendable {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case streaming
        case disconnected(reason: String)
    }

    private(set) var latest: MetricsSnapshot?
    private(set) var connectionState: ConnectionState = .idle

    private var readerThread: Thread?
    private var fd: Int32 = -1
    private var currentPID: Int32 = -1
    /// Throttle window. Snapshots arrive every 500ms but we only
    /// publish to SwiftUI once a second. Every re-render bubbles the
    /// hosting-view's intrinsic-size update to the inspector
    /// column's SplitViewChildController, which on macOS 26 hard-
    /// asserts when constraints invalidate mid-layout. Halving the
    /// publish rate halves the chance of catching that window.
    private var lastPublishedAt: Date = .distantPast
    private let publishInterval: TimeInterval = 1.0

    /// Open the socket for `pid` and start reading. Safe to call
    /// repeatedly with the same pid — no-op if already streaming
    /// from it.
    func connect(pid: Int32) {
        if connectionState == .streaming && currentPID == pid { return }
        disconnect()
        currentPID = pid
        connectionState = .connecting
        lastPublishedAt = .distantPast
        latest = nil

        let path = Self.socketPath(forPID: pid)
        let thread = Thread { [weak self] in
            self?.readerLoop(path: path, pid: pid)
        }
        thread.name = "solaro.metrics.reader"
        thread.start()
        readerThread = thread
    }

    /// Close the socket and drop any cached snapshot. Called when
    /// the aro subprocess exits or SOLARO is shutting down.
    func disconnect() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        readerThread = nil
        currentPID = -1
        if case .disconnected = connectionState { /* keep reason */ } else {
            connectionState = .idle
        }
    }

    static func socketPath(forPID pid: Int32) -> String {
        let dir = NSTemporaryDirectory()
        let trimmed = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return "\(trimmed)/aro-metrics-\(pid).sock"
    }

    // MARK: - Reader

    private func readerLoop(path: String, pid: Int32) {
        // Retry connect — aro might not have bound the socket yet
        // by the time SOLARO spawns it. Cap at ~3s of waiting.
        var sockFD: Int32 = -1
        for _ in 0..<30 {
            sockFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard sockFD >= 0 else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8) + [0]
            let pathLen = MemoryLayout.size(ofValue: addr.sun_path)
            if pathBytes.count > pathLen {
                close(sockFD)
                handleConnectFailure("socket path too long")
                return
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
                pathBytes.withUnsafeBufferPointer { src in
                    rawBuf.baseAddress?.copyMemory(
                        from: UnsafeRawPointer(src.baseAddress!),
                        byteCount: pathBytes.count
                    )
                }
            }
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    // Disambiguate from the instance method
                    // `connect(pid:)` above.
                    Darwin.connect(sockFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { break }
            close(sockFD)
            sockFD = -1
            Thread.sleep(forTimeInterval: 0.1)
        }

        if sockFD < 0 {
            handleConnectFailure("no socket at \(path)")
            return
        }
        self.fd = sockFD
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .streaming
        }

        // Line buffer — snapshots are NDJSON, one per line.
        let bufSize = 64 * 1024
        var rxBuf = [UInt8](repeating: 0, count: bufSize)
        var pending = Data()

        while !Thread.current.isCancelled {
            let n = rxBuf.withUnsafeMutableBytes { rawBuf -> Int in
                read(sockFD, rawBuf.baseAddress, bufSize)
            }
            if n <= 0 { break }
            pending.append(rxBuf, count: n)
            // Drain complete lines.
            while let nlIdx = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: pending.startIndex..<nlIdx)
                pending.removeSubrange(pending.startIndex...nlIdx)
                guard !lineData.isEmpty,
                      let snap = decode(lineData)
                else { continue }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let now = Date()
                    if now.timeIntervalSince(self.lastPublishedAt)
                        < self.publishInterval {
                        return // drop intermediate snapshot
                    }
                    self.lastPublishedAt = now
                    self.latest = snap
                }
            }
        }

        close(sockFD)
        if self.fd == sockFD { self.fd = -1 }
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .disconnected(reason: "stream ended")
        }
    }

    private func handleConnectFailure(_ reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .disconnected(reason: reason)
        }
    }

    private func decode(_ line: Data) -> MetricsSnapshot? {
        try? JSONDecoder().decode(MetricsSnapshot.self, from: line)
    }

    /// Inject a snapshot built outside the socket reader — used by the
    /// embedded runtime host (issue #282) so the Metrics tab still
    /// populates when there's no subprocess to host the push socket.
    /// Throttling deliberately doesn't apply: synthetic snapshots
    /// arrive on run-end (or once per second from a long-running
    /// embedded keepalive), so dropping them defeats the purpose.
    func publishSynthetic(_ snapshot: MetricsSnapshot) {
        connectionState = .streaming
        latest = snapshot
    }

    /// Reset back to idle — used when an embedded run finishes and we
    /// want the panel to show "no snapshot" until the next Run.
    func resetIdle() {
        connectionState = .idle
        latest = nil
    }
}
