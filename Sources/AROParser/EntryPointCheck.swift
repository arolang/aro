// ============================================================
// EntryPointCheck.swift
// AROParser — exactly one Application-Start (GitLab #581)
// ============================================================
//
// CLAUDE.md and ARO-0005 both state the rule as "exactly ONE
// `Application-Start` feature set per application (error if 0 or multiple)",
// and `ApplicationResolver` enforces it — at run time. So `aro check`, the
// tool whose job is to catch this before you run, passed an application that
// `aro run` then refused:
//
//     $ aro check .      ✅ No issues found in 1 file(s)
//     $ aro run .        Runtime error: Entry point not found: 'Application-Start'
//
// The rule lives here, as a value, rather than inside `CheckCommand` — so it
// can be tested without driving the CLI, the way `ComputeQualifierCatalog`
// sits here for the same reason. AROParser rather than ARORuntime because the
// check path never loads the runtime.

import Foundation

/// Whether a set of feature sets forms one application with one entry point.
public enum EntryPointCheck {

    /// The entry point the loader looks for.
    public static let entryPointName = "Application-Start"

    /// One feature set, and where it was declared.
    public struct Declaration: Sendable, Equatable {
        public let name: String
        public let activity: String
        /// Opaque grouping key — in practice the file, or the subdirectory it
        /// sits in. `EntryPointCheck` only compares these for equality.
        public let group: String

        public init(name: String, activity: String, group: String) {
            self.name = name
            self.activity = activity
            self.group = group
        }
    }

    public enum Result: Sendable, Equatable {
        /// Exactly one entry point.
        case ok

        /// None. `swapped` names a feature set whose *business activity* is
        /// `Application-Start` — the inverted header, which is the common way
        /// to arrive here because `(Name: Activity)` and
        /// `(Application-Start: Name)` look symmetrical and nothing complained.
        case missing(swapped: Declaration?)

        /// Several, all in one group: a single application with more than one
        /// entry point, which the loader rejects.
        case multiple([Declaration])

        /// Several, each in its own group: not a broken application but a
        /// *directory of* applications. `Examples/ModulesExample` is one, and
        /// `aro run` already tells the two apart, so the check must too —
        /// otherwise it reports an error the author cannot act on.
        case separateApplications(groups: [String])
    }

    /// Classify `declarations` — every feature set in the application.
    public static func classify(_ declarations: [Declaration]) -> Result {
        let starts = declarations.filter { $0.name == entryPointName }

        if starts.count == 1 { return .ok }

        if starts.isEmpty {
            let swapped = declarations.first { $0.activity == entryPointName }
            return .missing(swapped: swapped)
        }

        let groups = Set(starts.map(\.group)).sorted()
        if groups.count == starts.count, groups.count > 1 {
            return .separateApplications(groups: groups)
        }
        return .multiple(starts)
    }
}
