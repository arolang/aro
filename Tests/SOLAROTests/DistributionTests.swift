// ============================================================
// DistributionTests.swift
// SOLARO — update feed + signing identity discovery (#268)
// ============================================================

import Foundation
import Testing
@testable import SOLARO

@Suite("Update feed (#268)")
struct UpdateFeedTests {

    @Test("Newer versions compare above older ones")
    func ordering() {
        #expect(SolaroVersion.isNewer("0.12.0", than: "0.11.5"))
        #expect(SolaroVersion.isNewer("0.11.6", than: "0.11.5"))
        #expect(SolaroVersion.isNewer("1.0.0", than: "0.99.99"))
        #expect(!SolaroVersion.isNewer("0.11.5", than: "0.11.5"))
        #expect(!SolaroVersion.isNewer("0.11.4", than: "0.11.5"))
    }

    @Test("A leading v is not part of the version")
    func stripsVPrefix() {
        #expect(SolaroVersion.isNewer("v0.12.0", than: "0.11.5"))
        #expect(SolaroVersion.isNewer("0.12.0", than: "v0.11.5"))
        #expect(!SolaroVersion.isNewer("v0.11.5", than: "v0.11.5"))
    }

    @Test("Missing components read as zero")
    func differentLengths() {
        #expect(SolaroVersion.isNewer("0.12", than: "0.11.5"))
        #expect(!SolaroVersion.isNewer("0.11", than: "0.11.0"))
        #expect(SolaroVersion.isNewer("0.11.0.1", than: "0.11"))
    }

    @Test("Pre-release and build suffixes don't affect ordering")
    func suffixesIgnored() {
        #expect(SolaroVersion.components("0.12.0-rc.1") == [0, 12, 0])
        #expect(SolaroVersion.components("0.12.0+build.7") == [0, 12, 0])
        #expect(SolaroVersion.isNewer("0.12.0-rc.1", than: "0.11.9"))
    }

    @Test("A dev build is never told it is out of date")
    func devBuildNeverNags() {
        // `AROVersion.version` is the literal "dev" until the
        // pipeline stamps a tag in. Comparing that to a real
        // release would offer an "update" on every local launch.
        #expect(!SolaroVersion.isNewer("9.9.9", than: "dev"))
        #expect(!SolaroVersion.isNewer("dev", than: "0.11.5"))
    }

    @Test("Feed entries decode")
    func decodesFeed() throws {
        let json = """
        {"version": "0.12.0",
         "dmgURL": "https://aro.lang/downloads/solaro-macos-arm64.dmg",
         "notes": "Snippets tab, notarized DMG."}
        """
        let update = try JSONDecoder().decode(
            SolaroUpdate.self, from: Data(json.utf8))
        #expect(update.version == "0.12.0")
        #expect(update.notes?.isEmpty == false)
    }

    @Test("Notes are optional")
    func notesOptional() throws {
        let json = #"{"version": "0.12.0", "dmgURL": "https://x/y.dmg"}"#
        let update = try JSONDecoder().decode(
            SolaroUpdate.self, from: Data(json.utf8))
        #expect(update.notes == nil)
    }

    @Test("A feed missing the version field is a decode error")
    func malformedFeed() {
        let json = #"{"dmgURL": "https://x/y.dmg"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SolaroUpdate.self, from: Data(json.utf8))
        }
    }
}

@Suite("Signing identities (#268)")
struct SigningIdentityTests {

    /// Verbatim `security find-identity -v -p codesigning` output,
    /// including the trailing count line it always prints.
    private let sample = """
      1) 6006D0F8BCD84C17DAAFAE8787D57FD84D5CD405 "Apple Development: Kris Simon (VRNK5SH2WY)"
      2) 8B1492B3AD6178A155F00414FDB12F760727D450 "Apple Development: kris@ausdertechnik.de (TN3N449T48)"
      3) D01D7EEB214D5CC3CC9D82D2D82CBB8BAFB324DF "Developer ID Application: aus der Technik - Simon & Simon GbR (SR2JMV9NNY)"
         3 valid identities found
    """

    @Test("Parses the numbered identity lines")
    func parsesIdentities() {
        let identities = SigningIdentityScanner.parse(sample)
        #expect(identities.count == 3)
    }

    @Test("The trailing count line is not an identity")
    func ignoresCountLine() {
        let identities = SigningIdentityScanner.parse(sample)
        #expect(!identities.contains { $0.commonName.contains("valid identities") })
    }

    @Test("Team ID comes from the parenthesised suffix")
    func extractsTeamID() throws {
        let identities = SigningIdentityScanner.parse(sample)
        let developerID = try #require(identities.first { $0.canNotarize })
        #expect(developerID.teamID == "SR2JMV9NNY")
        #expect(developerID.owner == "aus der Technik - Simon & Simon GbR")
        #expect(developerID.kind == "Developer ID Application")
    }

    @Test("Only Developer ID Application can notarize")
    func notarizationCapability() {
        let identities = SigningIdentityScanner.parse(sample)
        #expect(identities.filter(\.canNotarize).count == 1)
        for identity in identities where identity.kind == "Apple Development" {
            #expect(!identity.canNotarize)
        }
    }

    @Test("Developer ID sorts first")
    func developerIDSortsFirst() {
        let identities = SigningIdentityScanner.parse(sample)
        #expect(identities.first?.canNotarize == true)
    }

    @Test("A name whose company ends in parentheses is not a Team ID")
    func doesNotMistakeTrailingParensForATeamID() {
        // Team IDs are exactly ten alphanumerics; "GmbH" is not.
        let identity = SigningIdentityScanner.make(
            sha1: "ABC",
            commonName: "Developer ID Application: Contoso (GmbH)")
        #expect(identity.teamID == nil)
        #expect(identity.owner == "Contoso (GmbH)")
    }

    @Test("Team IDs are upper-cased")
    func upperCasesTeamID() {
        let identity = SigningIdentityScanner.make(
            sha1: "ABC",
            commonName: "Developer ID Application: Contoso (ab12cd34ef)")
        #expect(identity.teamID == "AB12CD34EF")
    }

    @Test("A certificate with no kind prefix still parses")
    func handlesNameWithoutKind() {
        let identity = SigningIdentityScanner.make(
            sha1: "ABC", commonName: "Some Self-Signed Cert")
        #expect(identity.kind == "Certificate")
        #expect(identity.owner == "Some Self-Signed Cert")
        #expect(!identity.canNotarize)
    }

    @Test("Empty or noisy output yields no identities")
    func toleratesNoise() {
        #expect(SigningIdentityScanner.parse("").isEmpty)
        #expect(SigningIdentityScanner.parse("0 valid identities found").isEmpty)
        #expect(SigningIdentityScanner.parse(
            "security: SecKeychainSearchCopyNext: not found").isEmpty)
    }

    @Test("Display name carries the team ID for the picker")
    func displayName() {
        let identity = SigningIdentityScanner.make(
            sha1: "ABC",
            commonName: "Developer ID Application: Contoso (AB12CD34EF)")
        #expect(identity.displayName == "Contoso (AB12CD34EF) — Developer ID Application")
    }
}

// ============================================================
// Info.plist template parity (#539)
// ============================================================
//
// Solaro's Info.plist is generated by TWO heredoc templates —
// tools/build-solaro-app-local.sh and the GitHub release workflow.
// They have drifted before (the release plist shipped without the
// .aro document type for a while), and #539 was another instance:
// .repl notebooks were openable in-app but invisible to Launch
// Services. These tests read both templates from the repo and pin
// (a) that .repl is declared, and (b) that the two templates
// declare the same document types and UTIs at all.

@Suite("Info.plist templates (#539)")
struct InfoPlistTemplateTests {

    /// Repo root, located from this source file's own path
    /// (Tests/SOLAROTests/DistributionTests.swift → up three).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static let templatePaths = [
        "tools/build-solaro-app-local.sh",
        ".github/workflows/build.yml",
    ]

    private func template(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    /// All `<string>` values that follow `<key>keyName</key>` on the
    /// same line — the shape both heredocs use for scalar entries.
    private func values(forKey keyName: String, in text: String) -> [String] {
        let pattern = "<key>\(keyName)</key><string>([^<]*)</string>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    @Test(".repl notebooks are declared", arguments: templatePaths)
    func declaresReplNotebooks(path: String) throws {
        let text = try template(path)
        // The document type claims the exported UTI...
        #expect(values(forKey: "CFBundleTypeName", in: text)
            .contains("ARO notebook"))
        #expect(values(forKey: "UTTypeIdentifier", in: text)
            .contains("com.arolang.aro-notebook"))
        // ...and the UTI carries the extension Finder associates by.
        #expect(text.contains("<array><string>repl</string></array>"))
    }

    @Test("Local and release templates declare the same types")
    func templatesStayInSync() throws {
        let local = try template(Self.templatePaths[0])
        let release = try template(Self.templatePaths[1])
        for key in ["CFBundleTypeName", "UTTypeIdentifier", "CFBundleTypeRole", "LSHandlerRank"] {
            #expect(values(forKey: key, in: local) == values(forKey: key, in: release),
                    "templates drifted on \(key)")
        }
    }
}
