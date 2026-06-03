// ============================================================
// MetricsSocketServer.swift
// ARO Runtime - Unix-socket live metrics push for IDEs
// ============================================================
//
// Opens a Unix domain socket at $TMPDIR/aro-metrics-<pid>.sock
// and pushes one JSON snapshot per line every ~500ms to each
// connected client. SOLARO (and any other tooling) finds the
// socket by PID, connects, and renders the stream in real time.
//
// Wire format: newline-delimited JSON, server-pushed. No request/
// response handshake — connect and you start receiving snapshots
// on the next tick. Disconnect by closing the socket. Reconnect
// works.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Wire DTO mirroring `MetricsSnapshot` with a stable, IDE-friendly
/// shape. Hand-rolled instead of `Codable` on the existing types
/// because those have computed properties we want serialised
/// (`averageDurationMs`, `successRate`, …) and a few platform
/// types (`Date`) that we'd rather emit as ISO-8601 strings than
/// epoch doubles for log readability.
private struct MetricsSnapshotDTO: Encodable {
    let kind: String
    let collectedAt: String
    let uptimeSec: Double
    let totalExecutions: Int
    let totalSuccesses: Int
    let totalFailures: Int
    let featureSets: [FeatureSetDTO]
    let process: ProcessDTO

    struct FeatureSetDTO: Encodable {
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
    }

    struct ProcessDTO: Encodable {
        let cpuUserSec: Double
        let cpuSystemSec: Double
        let virtualMB: Double
        let residentMB: Double
        let openFDs: Int
    }

    init(from snap: MetricsSnapshot) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.kind = "snapshot"
        self.collectedAt = formatter.string(from: snap.collectedAt)
        self.uptimeSec = snap.uptimeSeconds
        self.totalExecutions = snap.totalExecutions
        self.totalSuccesses = snap.totalSuccesses
        self.totalFailures = snap.totalFailures
        self.featureSets = snap.featureSets.map { fs in
            FeatureSetDTO(
                name: fs.name,
                businessActivity: fs.businessActivity,
                count: fs.executionCount,
                successes: fs.successCount,
                failures: fs.failureCount,
                totalMs: fs.totalDurationMs,
                // `minDurationMs` defaults to .infinity until the
                // first execution lands — flatten that to 0 so
                // JSON consumers don't have to special-case it.
                minMs: fs.executionCount == 0 ? 0 : fs.minDurationMs,
                maxMs: fs.maxDurationMs,
                avgMs: fs.averageDurationMs,
                successRate: fs.successRate
            )
        }
        self.process = ProcessDTO(
            cpuUserSec: snap.processMetrics.cpuUserTime,
            cpuSystemSec: snap.processMetrics.cpuSystemTime,
            virtualMB: snap.processMetrics.virtualMemoryMB,
            residentMB: snap.processMetrics.residentMemoryMB,
            openFDs: snap.processMetrics.openFileDescriptors
        )
    }
}

/// Pushes `MetricsCollector.shared.snapshot()` over a Unix domain
/// socket every `pushInterval` to each connected client. Shared
/// singleton so `aro run` and embedded callers both reach for the
/// same instance.
public final class MetricsSocketServer: @unchecked Sendable {
    public static let shared = MetricsSocketServer()

    /// Cadence at which snapshots are pushed to each connected
    /// client. 500ms is fast enough that the SOLARO panel feels
    /// live without burning CPU re-serialising JSON.
    public var pushInterval: TimeInterval = 0.5

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var socketPath: String?
    private var clientFDs: Set<Int32> = []
    private var acceptThread: Thread?
    private var pushTask: Task<Void, Never>?
    private var isRunning = false

    public init() {}

    /// Conventional socket path for a given PID. SOLARO mirrors this
    /// computation to find the channel for the aro process it spawned.
    public static func socketPath(forPID pid: Int32) -> String {
        let dir = NSTemporaryDirectory()
        // Trim trailing slash to avoid `//` in the joined path.
        let trimmed = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return "\(trimmed)/aro-metrics-\(pid).sock"
    }

    /// Open the socket, bind, listen, and start the accept + push
    /// loops. Idempotent — calling `start()` twice is a no-op.
    @discardableResult
    public func start() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return socketPath }

        let path = MetricsSocketServer.socketPath(forPID: getpid())
        // Clean up a stale socket from a crashed previous run before
        // bind — otherwise `bind()` would fail with EADDRINUSE.
        unlink(path)

        // On Linux glibc, SOCK_STREAM is `__socket_type` (an enum) and
        // SHUT_RDWR is `Int`; on Darwin both are `Int32`. Use platform
        // shims so the same source compiles on both.
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else {
            FileHandle.standardError.write(Data(
                "[aro-metrics] socket() failed: \(String(cString: strerror(errno)))\n".utf8
            ))
            return nil
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path is a fixed-size C array tuple — copy bytes in via
        // withUnsafeMutableBytes so we don't have to enumerate the
        // tuple members manually.
        let pathBytes = Array(path.utf8) + [0]
        let pathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= pathLen else {
            FileHandle.standardError.write(Data(
                "[aro-metrics] socket path too long: \(path)\n".utf8
            ))
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            pathBytes.withUnsafeBufferPointer { src in
                rawBuf.baseAddress?.copyMemory(
                    from: UnsafeRawPointer(src.baseAddress!),
                    byteCount: pathBytes.count
                )
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            FileHandle.standardError.write(Data(
                "[aro-metrics] bind(\(path)) failed: \(String(cString: strerror(errno)))\n".utf8
            ))
            close(fd)
            return nil
        }

        guard listen(fd, 4) == 0 else {
            FileHandle.standardError.write(Data(
                "[aro-metrics] listen failed: \(String(cString: strerror(errno)))\n".utf8
            ))
            close(fd)
            unlink(path)
            return nil
        }

        self.listenFD = fd
        self.socketPath = path
        self.isRunning = true

        // Accept loop on a dedicated thread (blocking accept()).
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "aro.metrics.accept"
        thread.start()
        self.acceptThread = thread

        // Push loop via Task — periodic snapshot fan-out to clients.
        self.pushTask = Task.detached(priority: .utility) { [weak self] in
            await self?.pushLoop()
        }

        return path
    }

    /// Close the listener and all connected client sockets, remove
    /// the on-disk socket file. Called from RunCommand on shutdown
    /// and from a signal handler so a Ctrl-C doesn't leave a stale
    /// socket behind.
    public func stop() {
        lock.lock()
        let fd = listenFD
        let clients = clientFDs
        let path = socketPath
        listenFD = -1
        socketPath = nil
        clientFDs.removeAll()
        isRunning = false
        lock.unlock()

        pushTask?.cancel()
        pushTask = nil

        if fd >= 0 {
            // shutdown() unblocks any pending accept() in the
            // dedicated thread, then close() releases the FD.
            #if canImport(Glibc)
            shutdown(fd, Int32(SHUT_RDWR))
            #else
            shutdown(fd, SHUT_RDWR)
            #endif
            close(fd)
        }
        for client in clients {
            close(client)
        }
        if let path {
            unlink(path)
        }
    }

    // MARK: - Internals

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            let running = isRunning
            lock.unlock()
            guard running, fd >= 0 else { return }

            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &clientAddr, &len)
            if client < 0 {
                // EBADF / EINVAL after shutdown — bail. Other errors
                // (EINTR, …) shouldn't loop forever either; the
                // socket is single-purpose so giving up is fine.
                return
            }
            // Suppress SIGPIPE on writes to dead sockets so a client
            // hanging up doesn't take down the whole aro process.
            // Darwin uses a per-fd socket option; Linux relies on
            // MSG_NOSIGNAL in the send() flags below.
            #if canImport(Darwin)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE,
                       &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
            lock.lock()
            clientFDs.insert(client)
            lock.unlock()
        }
    }

    private func pushLoop() async {
        while !Task.isCancelled {
            // Sleep first so we don't fire a snapshot before anyone
            // could possibly have connected. 500ms cadence.
            let nanos = UInt64(pushInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            pushOneSnapshot()
        }
    }

    private func pushOneSnapshot() {
        lock.lock()
        let clients = clientFDs
        lock.unlock()
        guard !clients.isEmpty else { return }

        let dto = MetricsSnapshotDTO(from: MetricsCollector.shared.snapshot())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(dto) else { return }
        data.append(0x0A) // newline terminator

        var dead: [Int32] = []
        #if canImport(Glibc)
        let sendFlags: Int32 = Int32(MSG_NOSIGNAL)
        #else
        let sendFlags: Int32 = 0
        #endif
        data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let base = rawBuf.baseAddress else { return }
            for fd in clients {
                let written = send(fd, base, data.count, sendFlags)
                if written < 0 {
                    dead.append(fd)
                }
            }
        }
        if !dead.isEmpty {
            lock.lock()
            for fd in dead {
                clientFDs.remove(fd)
                close(fd)
            }
            lock.unlock()
        }
    }
}
