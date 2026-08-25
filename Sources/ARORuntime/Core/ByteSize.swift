// ============================================================
// ByteSize.swift
// ARO Runtime - Human-readable byte sizes (GitLab #477)
// ============================================================
//
// One parser for every place a byte budget is written by a
// human: `x-aro-max-body: 10MB` in a contract, `Configure the
// <http-server: max-body> with "1MB".` in ARO source, and
// `ARO_MAX_BODY=512KB` in the environment. They must agree, so
// they share this.

import Foundation

/// Parsing and formatting for byte quantities written the way people write
/// them — `1MB`, `512 KB`, `2GiB`, or a bare `1048576`.
///
/// Decimal suffixes are powers of 1000 and binary suffixes powers of 1024,
/// as the units say. `MB` is 1 000 000 bytes; `MiB` is 1 048 576. The
/// distinction rarely matters for a body limit, but silently rounding one
/// to the other would make a declared limit and an enforced limit differ,
/// which is exactly the kind of drift a contract is supposed to prevent.
public enum ByteSize {

    private static let decimalUnits: [(suffix: String, factor: Int)] = [
        ("kb", 1_000),
        ("mb", 1_000_000),
        ("gb", 1_000_000_000),
        ("tb", 1_000_000_000_000),
    ]

    private static let binaryUnits: [(suffix: String, factor: Int)] = [
        ("kib", 1 << 10),
        ("mib", 1 << 20),
        ("gib", 1 << 30),
        ("tib", 1 << 40),
    ]

    /// Parse a byte size. Returns `nil` when the text is not a size, so the
    /// caller can report the bad value rather than silently defaulting.
    ///
    /// Accepts an optional decimal fraction (`1.5MB`), optional whitespace
    /// before the unit, and any capitalisation. A bare number is bytes.
    public static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // Longest suffix first: "kib" must win over "b".
        let units = (binaryUnits + decimalUnits + [("b", 1)])
            .sorted { $0.suffix.count > $1.suffix.count }

        for unit in units where trimmed.hasSuffix(unit.suffix) {
            let numberPart = trimmed
                .dropLast(unit.suffix.count)
                .trimmingCharacters(in: .whitespaces)
            guard let magnitude = Double(numberPart), magnitude >= 0 else { return nil }
            let bytes = magnitude * Double(unit.factor)
            guard bytes <= Double(Int.max) else { return nil }
            return Int(bytes.rounded())
        }

        // No suffix: a plain byte count.
        if let plain = Int(trimmed), plain >= 0 { return plain }
        return nil
    }

    /// Format a byte count the way the parser accepts it, for error messages.
    /// Decimal units, so `describe` and `parse` round-trip: whatever an error
    /// message prints can be pasted back into `x-aro-max-body` and mean the
    /// same number.
    public static func describe(_ bytes: Int) -> String {
        let units: [(suffix: String, factor: Int)] = [
            ("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1_000),
        ]
        for unit in units where bytes >= unit.factor {
            let value = Double(bytes) / Double(unit.factor)
            if value == value.rounded() {
                return "\(Int(value))\(unit.suffix)"
            }
            return String(format: "%.1f%@", value, unit.suffix)
        }
        return "\(bytes) bytes"
    }
}
