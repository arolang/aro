// ============================================================
// MetricsSocketServer.swift
// ARO Runtime - Push metrics over a Unix domain socket
// ============================================================
//
// Opens `$TMPDIR/aro-metrics-<pid>.sock` and pushes a
// newline-delimited JSON snapshot to every connected client
// roughly twice per second. Consumed by SOLARO's MetricsPanel.
//
// Activation: only starts when `ARO_METRICS_SOCKET=1` is in
// the environment, so headless `aro run` invocations don't
// leave stray sockets in TMPDIR.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class MetricsSocketServer: @unchecked Sendable {
    public static let shared = MetricsSocketServer()

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFDs: [Int32] = []
    private var socketPath: String = ""
    private var stopFlag = false
    private var acceptThread: Thread?
    private var broadcastThread: Thread?
    private var started = false

    /// 500 ms between snapshots — matches SOLARO's ~2 Hz expectation.
    private let snapshotIntervalSec: Double = 0.5

    private init() {}

    // MARK: - Public lifecycle

    /// Start the server if `ARO_METRICS_SOCKET=1`. No-op otherwise,
    /// and no-op if already started. Failures are logged to stderr
    /// but never thrown — the metrics feed is non-essential.
    public func startIfEnabled() {
        guard ProcessInfo.processInfo.environment["ARO_METRICS_SOCKET"] == "1" else {
            return
        }
        start()
    }

    /// Force-start (ignores the env gate). Used by tests.
    public func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        stopFlag = false
        lock.unlock()

        let pid = getpid()
        let path = Self.socketPath(forPID: pid)

        // Clean up any stale socket file from a previous crash.
        unlink(path)

        let fd = socket(AF_UNIX, socketStreamType, 0)
        guard fd >= 0 else {
            logError("socket() failed: errno \(errno)")
            markStopped()
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        let pathCap = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count > pathCap {
            logError("socket path too long (\(pathBytes.count) > \(pathCap)): \(path)")
            close(fd)
            markStopped()
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

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            logError("bind() failed: errno \(errno) path=\(path)")
            close(fd)
            markStopped()
            return
        }
        if listen(fd, 8) != 0 {
            logError("listen() failed: errno \(errno)")
            close(fd)
            unlink(path)
            markStopped()
            return
        }

        lock.lock()
        listenFD = fd
        socketPath = path
        lock.unlock()

        let acceptT = Thread { [weak self] in self?.acceptLoop() }
        acceptT.name = "aro.metrics.accept"
        acceptT.start()

        let broadcastT = Thread { [weak self] in self?.broadcastLoop() }
        broadcastT.name = "aro.metrics.broadcast"
        broadcastT.start()

        lock.lock()
        acceptThread = acceptT
        broadcastThread = broadcastT
        lock.unlock()
    }

    /// Stop the server, close any connected clients, remove the
    /// socket file. Idempotent.
    public func stop() {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        stopFlag = true
        let listenCopy = listenFD
        listenFD = -1
        let clientsCopy = clientFDs
        clientFDs.removeAll()
        let pathCopy = socketPath
        socketPath = ""
        started = false
        lock.unlock()

        if listenCopy >= 0 {
            // Shutdown wakes any blocked accept() so the thread can
            // notice stopFlag and exit. close() alone is racy here.
            shutdown(listenCopy, shutdownReadWrite)
            close(listenCopy)
        }
        for fd in clientsCopy {
            shutdown(fd, shutdownReadWrite)
            close(fd)
        }
        if !pathCopy.isEmpty {
            unlink(pathCopy)
        }
    }

    // MARK: - Path

    public static func socketPath(forPID pid: Int32) -> String {
        let dir = NSTemporaryDirectory()
        let trimmed = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return "\(trimmed)/aro-metrics-\(pid).sock"
    }

    // MARK: - Threads

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            let stopping = stopFlag
            lock.unlock()
            if stopping || fd < 0 { return }

            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &addr, &len)
            if client < 0 {
                if errno == EINTR { continue }
                // listen fd closed during stop() → exit cleanly.
                return
            }

            // SIGPIPE on disconnected clients would otherwise kill
            // the whole aro process. Suppress per-socket on Darwin;
            // Linux uses MSG_NOSIGNAL at write time.
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE,
                       &one, socklen_t(MemoryLayout<Int32>.size))
            #endif

            lock.lock()
            if stopFlag {
                lock.unlock()
                close(client)
                return
            }
            clientFDs.append(client)
            lock.unlock()
        }
    }

    private func broadcastLoop() {
        while true {
            lock.lock()
            let stopping = stopFlag
            let clients = clientFDs
            lock.unlock()
            if stopping { return }

            if !clients.isEmpty {
                let snap = MetricsCollector.shared.snapshot()
                var line = MetricsWireFormat.encode(snap)
                line.append(0x0A) // LF terminator

                var dead: [Int32] = []
                line.withUnsafeBytes { rawBuf in
                    guard let base = rawBuf.baseAddress else { return }
                    for fd in clients {
                        if !writeAll(fd: fd, base: base, count: rawBuf.count) {
                            dead.append(fd)
                        }
                    }
                }
                if !dead.isEmpty {
                    lock.lock()
                    clientFDs.removeAll { dead.contains($0) }
                    lock.unlock()
                    for fd in dead {
                        shutdown(fd, shutdownReadWrite)
                        close(fd)
                    }
                }
            }

            Thread.sleep(forTimeInterval: snapshotIntervalSec)
        }
    }

    /// Write the whole buffer, retrying on partial writes / EINTR.
    /// Returns false on hard errors → caller drops the client.
    private func writeAll(fd: Int32, base: UnsafeRawPointer, count: Int) -> Bool {
        var written = 0
        while written < count {
            let remaining = count - written
            let ptr = base.advanced(by: written)
            #if canImport(Glibc)
            let n = send(fd, ptr, remaining, Int32(MSG_NOSIGNAL))
            #else
            let n = write(fd, ptr, remaining)
            #endif
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            written += n
        }
        return true
    }

    // MARK: - Helpers

    private func markStopped() {
        lock.lock()
        started = false
        lock.unlock()
    }

    private func logError(_ msg: String) {
        FileHandle.standardError.write(
            Data("[MetricsSocketServer] \(msg)\n".utf8)
        )
    }
}

// MARK: - Platform constants

#if canImport(Darwin)
private let socketStreamType: Int32 = SOCK_STREAM
private let shutdownReadWrite: Int32 = SHUT_RDWR
#else
private let socketStreamType: Int32 = Int32(SOCK_STREAM.rawValue)
private let shutdownReadWrite: Int32 = Int32(SHUT_RDWR)
#endif
