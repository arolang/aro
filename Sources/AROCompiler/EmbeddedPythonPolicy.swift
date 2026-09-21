// ============================================================
// EmbeddedPythonPolicy.swift
// AROCompiler — whether a Python plugin may be baked in (#856, #608)
// ============================================================
//
// One decision, in one place, so `aro build` and its tests agree about
// it: given some Python plugins, a link mode, and whatever CPython this
// machine can offer, does the build proceed — and if not, what is the
// person supposed to do about it?
//
// #608 established the rule that matters: a binary that looks
// standalone and dies on the target machine is worse than a build that
// declines. This keeps that rule and adds the case where the build can
// now say yes — a distribution whose CPython can actually be embedded.

import Foundation

public enum EmbeddedPythonPolicy {

    /// Set to `1` to build anyway and own the consequences.
    public static let overrideEnvironmentVariable = "ARO_ALLOW_EMBEDDED_PYTHON"

    public enum Decision: Equatable, Sendable {
        /// No Python plugins; nothing to decide.
        case notApplicable
        /// Embed the interpreter and its standard library. The binary
        /// is genuinely one file.
        case embedStatically(StaticPythonDistribution)
        /// Build, and say plainly that the result is not standalone.
        case buildWithWarning(reason: String)
        /// Decline, and say what would make it work.
        case refuse(reason: String)
    }

    /// How the binary is being linked, as far as this decision cares.
    public enum LinkMode: Equatable, Sendable {
        case staticLink
        case dynamicLink
    }

    /// Decide.
    ///
    /// - Parameters:
    ///   - plugins: names of the Python plugins found, for the message.
    ///   - linkMode: `--static` (the default) or `--dynamic`.
    ///   - distribution: what `StaticPythonDistribution.locate` found.
    ///   - buildMachinePython: the interpreter this machine would
    ///     otherwise have been linked against, named in the refusal so
    ///     the reader can see the paths the binary would have carried.
    ///   - overrideEnabled: the escape hatch, already read from the
    ///     environment by the caller.
    public static func decide(
        plugins: [String],
        linkMode: LinkMode,
        distribution: StaticPythonDistribution.Location,
        buildMachinePython: (executable: String, libraryPath: String, stdlibPath: String)?,
        overrideEnabled: Bool
    ) -> Decision {
        guard !plugins.isEmpty else { return .notApplicable }
        let named = plugins.sorted().map { "'\($0)'" }.joined(separator: ", ")

        // An embeddable CPython settles it, whichever link mode: the
        // binary carries its own interpreter either way, and that is
        // strictly better than borrowing the machine's.
        if case .found(let dist) = distribution {
            return .embedStatically(dist)
        }

        // `--dynamic` never claimed to be standalone. Say what it
        // depends on and build.
        if linkMode == .dynamicLink {
            return .buildWithWarning(
                reason: dependencyDescription(named: named,
                                              python: buildMachinePython,
                                              distribution: distribution))
        }

        if overrideEnabled {
            return .buildWithWarning(
                reason: dependencyDescription(named: named,
                                              python: buildMachinePython,
                                              distribution: distribution)
                    + "\n  (Built anyway because \(overrideEnvironmentVariable)=1; "
                    + "you now own the target machine's Python.)")
        }

        return .refuse(reason: refusal(named: named,
                                       python: buildMachinePython,
                                       distribution: distribution))
    }

    // MARK: - Messages

    static func dependencyDescription(
        named: String,
        python: (executable: String, libraryPath: String, stdlibPath: String)?,
        distribution: StaticPythonDistribution.Location
    ) -> String {
        var out = "Python plugin(s) \(named) — this binary is NOT standalone."
        if let python {
            out += """

              It needs a CPython interpreter and its standard library, which this build
              resolves from the machine it runs on:
                interpreter: \(python.executable)
                library:     \(python.libraryPath)
                stdlib:      \(python.stdlibPath)
              Copying it to a machine without that same Python installation will fail at startup.
            """
        } else {
            out += """

              It needs a CPython interpreter and its standard library, and no python3 was
              found on this machine — the plugin would be embedded as source with nothing
              to run it.
            """
        }
        if case .rejected(let why) = distribution {
            out += "\n  \(StaticPythonDistribution.environmentVariable) was set, but: \(why)"
        }
        return out
    }

    static func refusal(
        named: String,
        python: (executable: String, libraryPath: String, stdlibPath: String)?,
        distribution: StaticPythonDistribution.Location
    ) -> String {
        var out = "Python plugin(s) \(named) cannot be embedded in a standalone binary.\n"
        out += dependencyDescription(named: named, python: python,
                                     distribution: distribution)
            .split(separator: "\n").dropFirst()
            .joined(separator: "\n")
        out += """

          `aro build --static` (the default) produces one file you can copy, so those
          build-machine paths would be a lie.

          To build it standalone, give the build a CPython that can be embedded:
            \(StaticPythonDistribution.environmentVariable)=/path/to/dist aro build <app>
          It needs a real static `libpython<version>.a` and its standard library — a
          python-build-standalone distribution, or CPython configured with
          `--disable-shared`. A stock python.org or Homebrew install will not do: the
          file they call `libpython.a` is a symlink to the dynamic library.

          Otherwise, choose one:
            • aro build --dynamic <app>  — keep the dependency, and be told about it
            • aro run <app>              — the interpreter, where Python plugins work
            • port the plugin to Swift, C or Rust, which do bake into the binary
          Set \(overrideEnvironmentVariable)=1 to build anyway.
        """
        return out
    }
}
