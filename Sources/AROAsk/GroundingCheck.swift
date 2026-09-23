// ============================================================
// GroundingCheck.swift
// AROAsk - is the answer true about this project?
// ============================================================
//
// GitLab #876. `aro check` validates the *syntax* of ARO in an answer, and
// the repair loop fixes it when it fails. Nothing checks the prose. A claim
// that `Sources/Foo.swift` handles X, that an action named `Transmute`
// exists, or that ARO-0042 says something it does not, is returned
// unexamined — and those are the claims a user acts on.
//
// It matters more here than for a general assistant, because the model is
// fine-tuned on ARO and will confidently produce plausible ARO that is not
// in the language. That is the same failure GitLab #486 closed for Compute
// qualifiers at run time, reappearing in prose where no runtime will catch
// it.
//
// The reference implementation answers this with a second model — a
// co-located judge comparing the answer against the tool results. `aro ask`
// can do better for the highest-value subset, because it has a ground truth
// it can query without a model: a path either exists or it does not, a
// qualifier is in the catalogue or it is not, a proposal number resolves or
// it does not. A deterministic judge cannot hallucinate its own verdict.
//
// This is that subset. A model judge for the remainder is a separate piece
// of work, and it needs the small-model budget on a machine already running
// the main one.

import Foundation
import AROParser

/// Checks the checkable claims an answer makes about this project.
public struct GroundingCheck: Sendable {

    /// One claim that did not hold.
    public struct Finding: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A path the answer named that is not in the workspace.
            case missingPath(String)
            /// A proposal number that does not resolve.
            case missingProposal(String)
            /// A Compute qualifier that is in no catalogue.
            case unknownQualifier(String)
        }
        public var kind: Kind

        public var description: String {
            switch kind {
            case .missingPath(let p):
                return "the answer names '\(p)', which is not in this project"
            case .missingProposal(let n):
                return "the answer cites \(n), which does not exist"
            case .unknownQualifier(let q):
                return "the answer uses the qualifier '\(q)', which ARO does not have"
            }
        }
    }

    let root: URL
    let proposalNumbers: Set<String>

    public init(root: URL, proposalNumbers: Set<String>) {
        self.root = root
        self.proposalNumbers = proposalNumbers
    }

    /// Proposal identifiers that exist, read from `Proposals/`.
    public static func proposalNumbers(in root: URL) -> Set<String> {
        let dir = root.appendingPathComponent("Proposals")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.compactMap { name -> String? in
            guard name.hasPrefix("ARO-"), name.hasSuffix(".md") else { return nil }
            return String(name.prefix(8))   // "ARO-0042"
        })
    }

    // MARK: - The claims

    /// Workspace-relative paths an answer mentions.
    ///
    /// Only paths with a directory separator and a known source extension,
    /// because a bare word that happens to end in `.md` is prose often
    /// enough that treating it as a claim would produce noise — which is the
    /// failure #823 is about.
    static let pathPattern = #"(?<![\w/.])([A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+\.(?:aro|swift|md|yaml|yml|json))"#

    static let proposalPattern = #"\bARO-(\d{4})\b"#

    /// The qualifier slot of a Compute statement.
    ///
    /// Only Compute, because that is the slot whose namespace ARO-0019 §3.3
    /// closes. Every other `<name: qualifier>` in the language is a field
    /// access or a status — `<request: body>`, `<OK: status>` — and judging
    /// those against the Compute catalogue would reject correct code, which
    /// is worse than not judging.
    static let qualifierPattern =
        #"(?i)\b(?:Compute|Calculate|Derive)\s+(?:the\s+)?<[A-Za-z0-9_-]+:\s*([A-Za-z][A-Za-z0-9|.-]*)\s*>"#

    /// Every claim in `answer` that this project contradicts.
    public func inspect(answer: String) -> [Finding] {
        var findings: [Finding] = []
        var seen = Set<String>()

        for path in Self.matches(Self.pathPattern, in: answer) where !seen.contains(path) {
            seen.insert(path)
            let full = root.appendingPathComponent(path)
            if !FileManager.default.fileExists(atPath: full.path) {
                findings.append(Finding(kind: .missingPath(path)))
            }
        }

        for number in Self.matches(Self.proposalPattern, in: answer, group: 0)
        where !seen.contains(number) {
            seen.insert(number)
            if !proposalNumbers.contains(number) {
                findings.append(Finding(kind: .missingProposal(number)))
            }
        }

        for qualifier in Self.matches(Self.qualifierPattern, in: answer)
        where !seen.contains(qualifier) {
            seen.insert(qualifier)
            // A namespaced or chained qualifier is resolved at run time and
            // `aro check` deliberately accepts it, so it cannot be judged
            // here either.
            if qualifier.contains(".") || qualifier.contains("|") { continue }
            if ComputeQualifierCatalog.isUncheckable(qualifier) { continue }
            if !ComputeQualifierCatalog.isBuiltIn(qualifier) {
                findings.append(Finding(kind: .unknownQualifier(qualifier)))
            }
        }

        return findings
    }

    /// The correction to send when something did not hold.
    ///
    /// Names what is wrong and what to do, and asks for the answer again —
    /// not an apology. The reader wants the corrected answer.
    public static func correction(for findings: [Finding]) -> String {
        let listed = findings.map { "  - \($0.description)" }.joined(separator: "\n")
        return """
        Your answer makes claims this project contradicts:

        \(listed)

        Check them with the tools — read the file, list the actions, read the \
        proposal — and give the answer again with what is actually there.
        """
    }

    private static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group,
                  let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }
}
