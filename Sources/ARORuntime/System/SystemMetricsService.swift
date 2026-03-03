// ============================================================
// SystemMetricsService.swift
// ARO Runtime - System-Wide Metrics Collection
// ============================================================

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Collects real system-wide CPU, memory, and disk metrics.
///
/// Used by `RetrieveAction` when the object is `<system>`:
/// ```aro
/// Retrieve the <stats> from the <system>.
/// Retrieve the <cpu>    from the <system: cpu>.
/// Retrieve the <memory> from the <system: memory>.
/// Retrieve the <disk>   from the <system: disk>.
/// ```
///
/// Returns a dictionary:
/// ```
/// {
///   "cpu":    Int,       // system CPU usage % (0–100)
///   "memory": {
///     "used":    Int,    // used RAM in GB
///     "total":   Int,    // total RAM in GB
///     "percent": Int,    // used %
///   },
///   "disk": {
///     "used":    Int,    // used disk space in GB
///     "total":   Int,    // total disk space in GB
///     "percent": Int,    // used %
///   }
/// }
/// ```
public struct SystemMetricsService {

    /// Collect current system metrics and return as a sendable dictionary.
    public static func collect() async -> [String: any Sendable] {
        let cpu    = await collectCPU()
        let memory = collectMemory()
        let disk   = collectDisk()
        return ["cpu": cpu, "memory": memory, "disk": disk]
    }

    // MARK: - CPU
    //
    // Sample twice with a short interval so each call is self-contained.
    // Avoids cross-task shared state: Swift's concurrency scheduler gives no
    // visibility guarantees for plain static vars across task boundaries.

    private static func collectCPU() async -> Int {
        #if os(macOS)
        return await collectCPUDarwin()
        #elseif os(Linux)
        return await collectCPULinux()
        #else
        return 0
        #endif
    }

    #if os(macOS)
    private static func cpuTicksDarwin() -> (active: UInt64, total: UInt64)? {
        var cpuLoad = host_cpu_load_info()
        var infoCount = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &cpuLoad) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &infoCount)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // cpu_ticks tuple: (USER=0, SYSTEM=1, IDLE=2, NICE=3)
        let user   = UInt64(cpuLoad.cpu_ticks.0)
        let system = UInt64(cpuLoad.cpu_ticks.1)
        let idle   = UInt64(cpuLoad.cpu_ticks.2)
        let nice   = UInt64(cpuLoad.cpu_ticks.3)
        return (active: user + system + nice, total: user + system + idle + nice)
    }

    private static func collectCPUDarwin() async -> Int {
        guard let s1 = cpuTicksDarwin() else { return 0 }
        // Use GCD asyncAfter for the sampling delay — not cancelled when the
        // calling Swift task is in a cancellation state (unlike Task.sleep).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
                continuation.resume()
            }
        }
        guard let s2 = cpuTicksDarwin() else { return 0 }
        let deltaTotal  = s2.total  - s1.total
        let deltaActive = s2.active - s1.active
        guard deltaTotal > 0 else { return 0 }
        return Int((Double(deltaActive) / Double(deltaTotal) * 100.0).rounded())
    }
    #endif

    #if os(Linux)
    private static func cpuTicksLinux() -> (active: UInt64, total: UInt64)? {
        guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let firstLine = stat.components(separatedBy: "\n").first,
              firstLine.hasPrefix("cpu ") else { return nil }
        let parts = firstLine.split(separator: " ").dropFirst()
        let values = parts.compactMap { UInt64($0) }
        guard values.count >= 4 else { return nil }
        // /proc/stat cpu fields: user nice system idle iowait irq softirq ...
        let user   = values[0]
        let nice   = values[1]
        let system = values[2]
        let idle   = values[3]
        let active = user + nice + system
        let total  = active + idle + (values.count > 4 ? values[4...].reduce(0, +) : 0)
        return (active: active, total: total)
    }

    private static func collectCPULinux() async -> Int {
        guard let s1 = cpuTicksLinux() else { return 0 }
        // Use GCD asyncAfter for the sampling delay — not cancelled when the
        // calling Swift task is in a cancellation state (unlike Task.sleep).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
                continuation.resume()
            }
        }
        guard let s2 = cpuTicksLinux() else { return 0 }
        let deltaTotal  = s2.total  - s1.total
        let deltaActive = s2.active - s1.active
        guard deltaTotal > 0 else { return 0 }
        return Int((Double(deltaActive) / Double(deltaTotal) * 100.0).rounded())
    }
    #endif

    // MARK: - Memory

    private static func collectMemory() -> [String: any Sendable] {
        #if os(macOS)
        return collectMemoryDarwin()
        #elseif os(Linux)
        return collectMemoryLinux()
        #else
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return ["used": 0, "total": totalGB, "percent": 0]
        #endif
    }

    #if os(macOS)
    private static func collectMemoryDarwin() -> [String: any Sendable] {
        var vmStats = vm_statistics64_data_t()
        var infoCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &infoCount)
            }
        }

        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB    = Int(totalBytes / 1_073_741_824)

        guard kr == KERN_SUCCESS else {
            return ["used": 0, "total": totalGB, "percent": 0]
        }

        let pageSize   = UInt64(getpagesize())
        let activeGB   = UInt64(vmStats.active_count)   * pageSize / 1_073_741_824
        let wireGB     = UInt64(vmStats.wire_count)     * pageSize / 1_073_741_824
        let usedGB     = Int(activeGB + wireGB)
        let percent    = totalGB > 0 ? min(100, usedGB * 100 / totalGB) : 0

        return ["used": usedGB, "total": totalGB, "percent": percent]
    }
    #endif

    #if os(Linux)
    private static func collectMemoryLinux() -> [String: any Sendable] {
        var totalKB    = 0
        var availableKB = 0

        if let meminfo = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) {
            for line in meminfo.components(separatedBy: "\n") {
                if line.hasPrefix("MemTotal:") {
                    totalKB = parseKBValue(line)
                } else if line.hasPrefix("MemAvailable:") {
                    availableKB = parseKBValue(line)
                }
            }
        }

        let usedKB  = totalKB - availableKB
        let totalGB = totalKB / 1_048_576
        let usedGB  = usedKB  / 1_048_576
        let percent = totalGB > 0 ? min(100, usedGB * 100 / totalGB) : 0
        return ["used": usedGB, "total": totalGB, "percent": percent]
    }

    private static func parseKBValue(_ line: String) -> Int {
        // Lines look like: "MemTotal:       16384000 kB"
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return 0 }
        return Int(parts[1]) ?? 0
    }
    #endif

    // MARK: - Disk

    private static func collectDisk() -> [String: any Sendable] {
        let attrs      = try? FileManager.default.attributesOfFileSystem(forPath: "/")
        let totalBytes = (attrs?[.systemSize]     as? Int) ?? 0
        let freeBytes  = (attrs?[.systemFreeSize] as? Int) ?? 0
        let usedBytes  = totalBytes - freeBytes

        let totalGB = totalBytes / 1_073_741_824
        let usedGB  = usedBytes  / 1_073_741_824
        let percent = totalGB > 0 ? min(100, usedGB * 100 / totalGB) : 0
        return ["used": usedGB, "total": totalGB, "percent": percent]
    }
}
