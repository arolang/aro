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

        /// Entry points in more than one group: not one application but a
        /// *directory of* applications. `Examples/ModulesExample` is one, and
        /// `aro run` and `aro build` both refuse such a path and name a
        /// subdirectory to point at instead, so the check says the same.
        ///
        /// `groups` is every group declaring an entry point. `multipleWithin`
        /// is the subset declaring more than one — each of those is itself an
        /// application with too many, and naming them here is the difference
        /// between "check one of these" and "check one of these, and two of
        /// them are broken".
        case separateApplications(groups: [String], multipleWithin: [String])
    }

    /// Classify `declarations` — every feature set in the application.
    public static func classify(_ declarations: [Declaration]) -> Result {
        let starts = declarations.filter { $0.name == entryPointName }

        if starts.count == 1 { return .ok }

        if starts.isEmpty {
            let swapped = declarations.first { $0.activity == entryPointName }
            return .missing(swapped: swapped)
        }

        // More than one group means the path is a directory of applications,
        // whether or not each of them is itself well formed.
        //
        // Requiring one start per group (`groups.count == starts.count`) made
        // a whole tree collapse into "one application" as soon as any single
        // application inside it had two entry points: `aro check ./Examples`
        // answered "error: 111 Application-Start feature sets — an application
        // must have exactly one" and listed all 111, because one of the 109
        // examples is itself a directory of three (GitLab #824). Group first,
        // then report the groups that are individually broken.
        let startsByGroup = Dictionary(grouping: starts, by: \.group)
        if startsByGroup.count > 1 {
            return .separateApplications(
                groups: startsByGroup.keys.sorted(),
                multipleWithin: startsByGroup.filter { $0.value.count > 1 }.keys.sorted()
            )
        }
        return .multiple(starts)
    }
}
