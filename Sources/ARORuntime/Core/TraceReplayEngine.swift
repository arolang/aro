// ============================================================
// TraceReplayEngine.swift
// ARO Runtime — time-travel "branch & edit" replay (#447)
// ============================================================
//
// Powers SOLARO's forked time-travel: take a recorded feature-set run, seed a
// fresh context with the symbol state as of some tick (with one value the user
// mutated), and re-run the statements from that tick onward in an isolated
// sandbox — producing a forked trace SOLARO renders as a sibling rail.
//
// The runtime side of this is `FeatureSetExecutor.replayTrace`; this type is
// the high-level, in-process entry point SOLARO calls with the open project's
// source. Because recorded values arrive as strings (the JSONL trace is
// flat-string), `reconstruct` best-effort re-types them; complex object graphs
// degrade to their string form, which is an inherent limit of trace replay.

import Foundation
import AROParser

public enum TraceReplayEngine {

    /// A forked trace: the per-statement snapshots produced by replaying from
    /// `startIndex` with the seeded (and mutated) state.
    public struct Fork: Sendable {
        public let featureSetName: String
        public let startIndex: Int
        public let steps: [FeatureSetExecutor.ReplayStep]
        public let responseSummary: String?
        public let error: String?
    }

    public enum ReplayError: Error, CustomStringConvertible {
        case compileFailed([String])
        case featureSetNotFound(String)

        public var description: String {
            switch self {
            case .compileFailed(let errs):
                return "replay source did not compile: \(errs.joined(separator: "; "))"
            case .featureSetNotFound(let name):
                return "feature set '\(name)' not found in the replay source"
            }
        }
    }

    // MARK: - Value reconstruction

    /// Best-effort re-typing of a stringified trace value into a Sendable the
    /// runtime can bind: bool / int / double / JSON object|array (recursively)
    /// / else the raw string.
    public static func reconstruct(_ raw: String) -> any Sendable {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "true" { return true }
        if t == "false" { return false }
        if let i = Int(t) { return i }
        if let d = Double(t), t.rangeOfCharacter(from: CharacterSet(charactersIn: ".eE")) != nil {
            return d
        }
        if (t.hasPrefix("{") || t.hasPrefix("[")),
           let data = t.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            return jsonToSendable(obj)
        }
        return raw
    }

    private static func jsonToSendable(_ value: Any) -> any Sendable {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            // Integral if it has no fractional part.
            if n.doubleValue == n.doubleValue.rounded() && abs(n.doubleValue) < 9.0e15 {
                return n.intValue
            }
            return n.doubleValue
        case let arr as [Any]:
            return arr.map { jsonToSendable($0) } as [any Sendable]
        case let dict as [String: Any]:
            var out: [String: any Sendable] = [:]
            for (k, v) in dict { out[k] = jsonToSendable(v) }
            return out
        case is NSNull:
            return ""
        default:
            return String(describing: value)
        }
    }

    // MARK: - Replay

    /// Compile `source`, locate `featureSetName`, seed an isolated context with
    /// `seeds`, and replay statements from `startIndex`. Runs entirely
    /// in-process against throwaway storage — a replayed Store/Emit cannot touch
    /// the real run's state.
    ///
    /// - Parameters:
    ///   - source: concatenation of the project's `.aro` sources (enough for the
    ///     target feature set to compile).
    ///   - seeds: symbol name → already-typed value. Callers converting from a
    ///     recorded trace should map string values through `reconstruct` first.
    public static func replay(
        source: String,
        featureSetName: String,
        startIndex: Int,
        seeds: [String: any Sendable]
    ) async throws -> Fork {
        let analyzed = try resolve(source: source, featureSetName: featureSetName)
        return await run(analyzed, startIndex: startIndex, seeds: seeds)
    }

    /// Replay entry point keyed by a source **line** rather than a statement
    /// index — the shape SOLARO has from a recorded tick. Maps the line to the
    /// first statement at or after it; falls back to the start of the feature
    /// set when nothing matches.
    public static func replay(
        source: String,
        featureSetName: String,
        fromLine line: Int,
        seeds: [String: any Sendable]
    ) async throws -> Fork {
        let analyzed = try resolve(source: source, featureSetName: featureSetName)
        let statements = analyzed.featureSet.statements
        var idx = statements.firstIndex { $0.span.start.line == line }
            ?? statements.firstIndex { $0.span.start.line >= line }
            ?? 0
        idx = max(0, min(idx, statements.count))
        return await run(analyzed, startIndex: idx, seeds: seeds)
    }

    private static func resolve(source: String, featureSetName: String) throws -> AnalyzedFeatureSet {
        let result = Compiler().compile(source)
        let errors = result.diagnostics
            .filter { $0.severity == .error }
            .map { String(describing: $0) }
        guard errors.isEmpty else { throw ReplayError.compileFailed(errors) }
        guard let analyzed = result.analyzedProgram.byName[featureSetName] else {
            throw ReplayError.featureSetNotFound(featureSetName)
        }
        return analyzed
    }

    private static func run(
        _ analyzed: AnalyzedFeatureSet,
        startIndex: Int,
        seeds: [String: any Sendable]
    ) async -> Fork {
        // Isolated sandbox: fresh event bus + throwaway in-memory storage.
        let bus = EventBus()
        let container = RuntimeContainer(
            eventBus: bus,
            repositoryStorage: InMemoryRepositoryStorage()
        )
        let ctx = RuntimeContext(
            featureSetName: analyzed.featureSet.name,
            businessActivity: analyzed.featureSet.businessActivity,
            eventBus: bus,
            container: container
        )
        for (name, value) in seeds {
            ctx.bind(name, value: value, allowRebind: true)
        }

        let executor = FeatureSetExecutor(
            actionRegistry: ActionRegistry.shared,
            eventBus: bus,
            globalSymbols: GlobalSymbolStorage()
        )
        let r = await executor.replayTrace(analyzed, seededContext: ctx, from: startIndex)
        return Fork(
            featureSetName: analyzed.featureSet.name,
            startIndex: startIndex,
            steps: r.steps,
            responseSummary: r.responseSummary,
            error: r.error
        )
    }
}
