// ============================================================
// FileMode.swift
// ARO Runtime — POSIX permission bits, written the two ways people write them
// ARO-0036 §10, GitLab #861
// ============================================================
//
// `Stat` has always *read* permissions and rendered them symbolically
// (`rwxr-xr-x`). Nothing could set them. Making that round-trip is the point of
// accepting both spellings here: reading the mode off one file and applying it
// to another is the obvious first thing to want, and it only works if the
// setter accepts what the getter produces.

import Foundation

/// A POSIX permission mode.
public struct FileMode: Sendable, Equatable {
    /// The raw permission bits, `0o000`–`0o777`.
    public let bits: Int

    public init?(bits: Int) {
        guard bits >= 0, bits <= 0o7777 else { return nil }
        self.bits = bits
    }

    /// Parse `"755"`, `"0755"`, or the `"rwxr-xr-x"` form `Stat` prints.
    ///
    /// Returns `nil` rather than guessing. A mode is three digits or nine
    /// characters and nothing else looks like one, so anything else is a typo
    /// — and a chmod that silently did something other than what was written
    /// is the one outcome worth ruling out.
    public static func parse(_ raw: String) -> FileMode? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // Symbolic: exactly the nine characters Stat emits. A leading type
        // character (`-rwxr-xr-x`, as `ls -l` prints) is accepted too, because
        // that is what people paste.
        let symbolic = text.count == 10 ? String(text.dropFirst()) : text
        if symbolic.count == 9, symbolic.allSatisfy({ "rwx-".contains($0) }) {
            var bits = 0
            for (index, character) in symbolic.enumerated() {
                let bit: Int
                switch index % 3 {
                case 0: bit = 4      // r
                case 1: bit = 2      // w
                default: bit = 1     // x
                }
                if character != "-" { bits |= bit << (6 - (index / 3) * 3) }
            }
            return FileMode(bits: bits)
        }

        // Octal, with or without a leading zero. Parsed strictly base 8:
        // `"0755"` and `"755"` are the same mode, and `"799"` is not a mode
        // at all rather than some other number.
        guard text.allSatisfy({ $0.isNumber }), text.count <= 4,
              let bits = Int(text, radix: 8) else { return nil }
        return FileMode(bits: bits)
    }

    /// `"rwxr-xr-x"` — the same rendering `Stat` produces, so a mode read from
    /// one file and written to another survives the round trip unchanged.
    public var symbolic: String {
        let chars = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        return chars[(bits >> 6) & 0o7] + chars[(bits >> 3) & 0o7] + chars[bits & 0o7]
    }

    /// `"755"`.
    public var octal: String {
        String(bits & 0o7777, radix: 8)
    }

    /// What the accepted spellings are, for an error message.
    public static let expected =
        "an octal mode like \"755\" or \"0644\", or the symbolic form Stat prints, \"rwxr-xr-x\""
}
