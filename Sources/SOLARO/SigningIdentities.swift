// ============================================================
// SigningIdentities.swift
// SOLARO — Developer ID discovery for the Signing settings (#268)
// ============================================================
//
// Signing and notarizing a release needs an Apple Developer Team
// ID. Asking someone to go find a ten-character string in their
// Apple Developer account is a bad first step, and typing it wrong
// fails late — the notary rejects the submission after the upload.
//
// The Team ID is already on the machine: every codesigning
// certificate carries it in the parenthesised suffix of its common
// name. So enumerate the local keychain identities and let the user
// *pick* one, with the free-text field kept as the fallback for a
// CI-only Team ID that has no local cert.
//
// The other thing worth surfacing here: only a **Developer ID
// Application** certificate can notarize. Apple Development and
// Apple Distribution certs sign fine and then fail at the notary,
// which is the confusing failure the release workflow already warns
// about in a shell comment. Better to say it in the UI, next to the
// identity that can't do it.

import Foundation

/// One codesigning identity in the login keychain.
struct SigningIdentity: Identifiable, Hashable, Sendable {
    /// SHA-1 of the certificate — what `codesign --sign` accepts
    /// unambiguously when two certs share a common name.
    var sha1: String
    /// Full common name, e.g.
    /// `Developer ID Application: ACME GmbH (AB12CD34EF)`.
    var commonName: String
    /// Certificate kind, the part before the first `: `.
    var kind: String
    /// Human part of the name, between `: ` and the team suffix.
    var owner: String
    /// The parenthesised ten-character Team ID, when present.
    var teamID: String?

    var id: String { sha1 }

    /// True when this certificate can actually notarize. Apple
    /// Development / Apple Distribution certs cannot — the notary
    /// returns Invalid after the upload.
    var canNotarize: Bool { kind == "Developer ID Application" }

    /// What the picker row shows.
    var displayName: String {
        guard let teamID else { return "\(owner) — \(kind)" }
        return "\(owner) (\(teamID)) — \(kind)"
    }
}

enum SigningIdentityScanner {
    /// Parse the output of `security find-identity -v -p codesigning`.
    ///
    /// Lines look like:
    /// ```
    ///   1) A1B2… "Developer ID Application: ACME GmbH (AB12CD34EF)"
    ///      2 valid identities found
    /// ```
    /// Anything that doesn't match the numbered form is skipped, so
    /// the trailing count line and `security`'s occasional warnings
    /// pass through harmlessly.
    static func parse(_ output: String) -> [SigningIdentity] {
        var identities: [SigningIdentity] = []
        for line in output.split(omittingEmptySubsequences: true,
                                 whereSeparator: \.isNewline)
        {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `<n>) <sha1> "<common name>"`
            guard let parenIndex = trimmed.firstIndex(of: ")"),
                  Int(trimmed[trimmed.startIndex..<parenIndex]) != nil,
                  let firstQuote = trimmed.firstIndex(of: "\""),
                  let lastQuote = trimmed.lastIndex(of: "\""),
                  firstQuote < lastQuote
            else { continue }

            let sha1 = trimmed[trimmed.index(after: parenIndex)..<firstQuote]
                .trimmingCharacters(in: .whitespaces)
            guard !sha1.isEmpty else { continue }
            let commonName = String(
                trimmed[trimmed.index(after: firstQuote)..<lastQuote])
            guard !commonName.isEmpty else { continue }

            identities.append(
                make(sha1: sha1, commonName: commonName))
        }
        // Developer ID first — it's the only kind that ships.
        return identities.sorted {
            if $0.canNotarize != $1.canNotarize { return $0.canNotarize }
            return $0.displayName < $1.displayName
        }
    }

    /// Split a common name into kind / owner / team ID.
    static func make(sha1: String, commonName: String) -> SigningIdentity {
        var kind = ""
        var remainder = commonName
        if let separator = commonName.range(of: ": ") {
            kind = String(commonName[commonName.startIndex..<separator.lowerBound])
            remainder = String(commonName[separator.upperBound...])
        }

        var owner = remainder
        var teamID: String?
        if remainder.hasSuffix(")"),
           let open = remainder.lastIndex(of: "(")
        {
            let candidate = String(
                remainder[remainder.index(after: open)..<remainder.index(before: remainder.endIndex)])
            // Apple Team IDs are ten alphanumerics. Checking the
            // shape keeps a company name that merely ends in
            // parentheses from being read as a Team ID.
            if candidate.count == 10,
               candidate.allSatisfy({ $0.isLetter || $0.isNumber })
            {
                teamID = candidate.uppercased()
                owner = String(remainder[remainder.startIndex..<open])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        return SigningIdentity(
            sha1: sha1,
            commonName: commonName,
            kind: kind.isEmpty ? "Certificate" : kind,
            owner: owner,
            teamID: teamID
        )
    }

    /// Shell out to `security` and parse. Returns an empty list when
    /// the tool is missing or errors — the settings panel falls back
    /// to the manual field, which is also the CI-only case.
    static func scan() -> [SigningIdentity] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(data: data, encoding: .utf8) ?? "")
    }
}

/// Persisted signing preferences. The Team ID is the one value the
/// release scripts need; the SHA-1 is remembered so the picker can
/// re-select the same row after a rescan.
@MainActor
@Observable
final class SigningSettings {
    private(set) var identities: [SigningIdentity] = []
    private(set) var isScanning = false

    var teamID: String {
        get { UserDefaults.standard.string(forKey: SolaroPrefs.signingTeamID.rawValue) ?? "" }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces).uppercased(),
                                      forKey: SolaroPrefs.signingTeamID.rawValue)
        }
    }

    var identitySHA1: String {
        get { UserDefaults.standard.string(forKey: SolaroPrefs.signingIdentity.rawValue) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: SolaroPrefs.signingIdentity.rawValue) }
    }

    /// The identity matching the stored SHA-1, if it's still in the
    /// keychain.
    var selectedIdentity: SigningIdentity? {
        identities.first { $0.sha1 == identitySHA1 }
    }

    /// True when a Team ID is configured but no local certificate
    /// can notarize with it — worth saying out loud, since the
    /// failure otherwise arrives at the end of a release build.
    var lacksNotarizingCertificate: Bool {
        !teamID.isEmpty && !identities.contains { $0.canNotarize && $0.teamID == teamID }
    }

    func rescan() {
        isScanning = true
        identities = SigningIdentityScanner.scan()
        isScanning = false
        // First run with exactly one usable identity: pre-select it
        // rather than making the user choose from a list of one.
        if identitySHA1.isEmpty, teamID.isEmpty {
            let notarizing = identities.filter(\.canNotarize)
            if let only = notarizing.count == 1 ? notarizing.first : nil {
                select(only)
            }
        }
    }

    func select(_ identity: SigningIdentity) {
        identitySHA1 = identity.sha1
        if let team = identity.teamID { teamID = team }
    }
}
