// ============================================================
// UpdateCheck.swift
// SOLARO — hand-rolled update feed poll (#268)
// ============================================================
//
// A notarized DMG is only half of distribution: the other half is
// telling someone a newer one exists. Sparkle would bring a whole
// update framework (and its own signing story) for what is, at our
// release cadence, one JSON fetch. So: poll
// https://aro.lang/solaro-updates.json, compare, link to the DMG.
//
// Deliberately *not* an auto-updater. It never downloads anything
// on its own — the user clicks through to the DMG in their browser.
// Nothing is sent to the server beyond the request itself, which is
// what lets this sit next to ADR-007/010 (no telemetry).

import Foundation
import AROVersion

/// One entry in `solaro-updates.json`:
/// `{"version": "0.12.0", "dmgURL": "https://…dmg", "notes": "…"}`.
struct SolaroUpdate: Codable, Equatable, Sendable {
    var version: String
    var dmgURL: String
    var notes: String?

    /// The feed the app polls. Overridable through
    /// `SOLARO_UPDATE_FEED` so a release rehearsal can point at a
    /// staging file without a rebuild.
    static var feedURL: URL {
        if let override = ProcessInfo.processInfo.environment["SOLARO_UPDATE_FEED"],
           let url = URL(string: override)
        {
            return url
        }
        // Force-unwrap: a literal that has parsed since the day it
        // was written. A typo here fails on the first launch.
        return URL(string: "https://aro.lang/solaro-updates.json")!
    }
}

/// Dotted-numeric version ordering, tolerant of the shapes our
/// builds actually produce: `v0.11.5`, `0.11.5`, `0.12`,
/// `0.12.0-rc.1`, and the `dev` sentinel of a local build.
enum SolaroVersion {
    /// Numeric components, pre-release suffix stripped.
    static func components(_ raw: String) -> [Int] {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        // Everything from the first `-` (pre-release) or `+`
        // (build metadata) on is not part of the ordering we do.
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[text.startIndex..<cut])
        }
        let parts = text.split(separator: ".")
        // The leading component has to be a number for this to be a
        // version at all. Without the check, the `dev` sentinel of an
        // un-stamped local build parses to [0] and every release
        // looks newer — an update banner on every developer launch.
        guard let first = parts.first, Int(first) != nil else { return [] }
        return parts.map { Int($0) ?? 0 }
    }

    /// True when `candidate` orders strictly above `current`.
    ///
    /// A local `dev` build parses to no components; treating that
    /// as "older than everything" would nag every developer on
    /// every launch, so it compares as *newer* — nothing to offer.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let currentParts = components(current)
        guard !currentParts.isEmpty else { return false }
        let candidateParts = components(candidate)
        guard !candidateParts.isEmpty else { return false }
        let width = max(currentParts.count, candidateParts.count)
        for index in 0..<width {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}

/// What the Welcome footer renders.
enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate
    case available(SolaroUpdate)
    case failed(String)
}

@MainActor
@Observable
final class UpdateChecker {
    private(set) var state: UpdateCheckState = .idle

    /// Version this build reports. Injected so tests don't depend
    /// on the stamped-in value.
    private let currentVersion: String
    private let session: URLSession

    init(currentVersion: String = AROVersionShim.shortVersion,
         session: URLSession = .shared)
    {
        self.currentVersion = currentVersion
        self.session = session
    }

    /// Fetch the feed and classify the result. Always user-
    /// initiated — nothing calls this on a timer.
    func check() async {
        state = .checking
        do {
            var request = URLRequest(url: SolaroUpdate.feedURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode)
            {
                state = .failed("Update feed returned HTTP \(http.statusCode).")
                return
            }
            let update = try JSONDecoder().decode(SolaroUpdate.self, from: data)
            state = SolaroVersion.isNewer(update.version, than: currentVersion)
                ? .available(update)
                : .upToDate
        } catch is DecodingError {
            state = .failed("Update feed is not in the expected format.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Indirection over `AROVersion` so this file (and its tests) don't
/// need the version module at hand to reason about comparison.
enum AROVersionShim {
    static var shortVersion: String { AROVersion.shortVersion }
}
