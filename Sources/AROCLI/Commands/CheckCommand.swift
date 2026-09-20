// ============================================================
// CheckCommand.swift
// ARO CLI - Check Command
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import AROPackageManager
import AROVersion
import ARORuntime

struct CheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check ARO source files or plugins",
        subcommands: [SourceCheckSubcommand.self, PluginCheckSubcommand.self],
        defaultSubcommand: SourceCheckSubcommand.self
    )
}

// MARK: - Source Check

struct SourceCheckSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "source",
        abstract: "Check ARO source files for errors"
    )

    @Argument(help: "Path to source file or directory (or `-` for stdin / inline snippet when --syntax is set)")
    var path: String

    @Flag(name: .long, inversion: .prefixedNo, help: "Show warnings")
    var warnings: Bool = true

    @Flag(name: .long, help: "Show verbose diagnostic information")
    var verbose: Bool = false

    @Flag(
        name: .long,
        help: """
            Check a bare ARO snippet (single statement, block of statements,
            or feature-set body) instead of a full program. The argument may be \
            a file path, an inline snippet string, or `-` for stdin. Useful for \
            REPL-style fragments and for training-pipeline validators that \
            need to gate per-pair output without requiring a feature-set \
            wrapper around every example.
            """
    )
    var syntax: Bool = false

    @Flag(
        name: [.long, .customShort("r")],
        help: """
            Check every application under the path separately instead of \
            treating them as one. Without it, a directory holding several \
            applications is an error -- the same answer `aro run` and \
            `aro build` give.
            """
    )
    var recursive: Bool = false

    func run() throws {
        if syntax {
            try runSyntaxOnly()
            return
        }

        let resolvedPath = URL(fileURLWithPath: path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath.path, isDirectory: &isDirectory) else {
            print("Error: Path not found: \(path)")
            throw ExitCode.failure
        }

        if recursive {
            guard isDirectory.boolValue else {
                print("Error: --recursive needs a directory, not a file")
                throw ExitCode.failure
            }
            try runRecursive(root: resolvedPath)
            return
        }

        let (errors, warnings) = try checkApplication(
            at: resolvedPath,
            isDirectory: isDirectory.boolValue
        )

        if errors > 0 {
            Foundation.exit(1)
        }
        _ = warnings
    }

    /// Check one path -- a single file, or a directory treated as one
    /// application -- and print its report.
    ///
    /// Split out of `run()` so `--recursive` can call it once per application
    /// without the summary and the exit code being decided here (GitLab #824).
    /// - Returns: the error and warning counts for this path.
    @discardableResult
    private func checkApplication(at resolvedPath: URL, isDirectory: Bool) throws -> (Int, Int) {
        let sourceFiles: [URL]

        if isDirectory {
            sourceFiles = try findSourceFiles(in: resolvedPath)
        } else {
            sourceFiles = [resolvedPath]
        }

        if sourceFiles.isEmpty {
            print("Error: No .aro files found")
            throw ExitCode.failure
        }

        var totalErrors = 0
        var totalWarnings = 0

        // Which events the application handles, before checking any single
        // file. An ARO application has no imports — every feature set is
        // visible to every other — but this command compiles a file at a
        // time, so on its own the orphan-event check can only see the
        // handlers that happen to live in the file doing the emitting.
        //
        // Every handler in a sibling file was therefore reported missing.
        // The Crawler example emits SavePage, ExtractLinks and QueueUrl from
        // crawler.aro and main.aro and handles all three — in storage.aro
        // and links.aro — and `aro check` called all three unhandled. Acting
        // on that advice appends a duplicate handler and the real one stops
        // being the only one.
        let handledEvents = handledEventTypes(in: sourceFiles)

        // Same seam, same reason, for `Application.<Name>` (GitLab #587): a
        // user-defined action is visible application-wide, so a call answered
        // by a declaration in a sibling file was reported unknown — under a
        // hint that flatly denied any action was declared at all.
        //
        // `nil` for a single named file: that file may well be one of many in
        // an application this invocation was never pointed at, so the
        // diagnostic must not speak for the application.
        let declaredActions: UserActionRegistry? = isDirectory
            ? UserActionRegistry.declared(inFiles: sourceFiles)
            : nil

        for sourceFile in sourceFiles {
            let (errors, warnings) = try checkFile(
                sourceFile,
                handledEvents: handledEvents,
                declaredActions: declaredActions
            )
            totalErrors += errors
            totalWarnings += warnings
        }

        // Transitions the contract does not declare (GitLab #507).
        // Directory-scoped: the state enums live in `openapi.yaml`, which a
        // single-file check has no application root to find.
        if isDirectory {
            totalErrors += reportUndeclaredTransitions(directory: resolvedPath, sourceFiles: sourceFiles)
        }

        // Exactly one Application-Start (GitLab #581).
        // Directory-scoped: a single named file may be one of many in an
        // application this invocation was never pointed at, so it must not
        // speak for the application — the same reasoning as `declaredActions`.
        if isDirectory {
            totalErrors += reportEntryPoint(directory: resolvedPath, sourceFiles: sourceFiles)
        }

        // Where each route's request body goes (GitLab #477).
        if isDirectory {
            totalWarnings += reportBodyPolicies(directory: resolvedPath, sourceFiles: sourceFiles)
        }

        // Summary
        print()
        if totalErrors == 0 && totalWarnings == 0 {
            print("✅ No issues found in \(sourceFiles.count) file(s)")
        } else {
            if totalErrors > 0 {
                print("❌ \(totalErrors) error(s) found")
            }
            if totalWarnings > 0 && warnings {
                print("⚠️  \(totalWarnings) warning(s) found")
            }
        }

        return (totalErrors, totalWarnings)
    }

    /// Report `Accept` statements that name a state the contract does not
    /// declare (GitLab #507).
    ///
    /// The runtime checks that the entity is *in* the transition's from-state;
    /// it never knew which moves exist. The contract does: an entity's states
    /// are the string `enum` on its state property. Both halves of a
    /// transition name must be members, and a state that is not declared is
    /// an error here — before the program runs, before a binary is built.
    ///
    /// No contract, or no enum on that property, means no enforcement. That
    /// is deliberate: contract-first is opt-in everywhere else in ARO (no
    /// `openapi.yaml`, no HTTP server), and a project that never wrote one
    /// must keep checking clean.
    /// - Returns: the number of errors emitted.
    private func reportUndeclaredTransitions(directory: URL, sourceFiles: [URL]) -> Int {
        guard let contract = OpenAPILoader.findContract(in: directory),
              let spec = try? OpenAPILoader.load(from: contract)
        else { return 0 }

        var errorCount = 0
        for file in sourceFiles {
            guard let source = try? String(contentsOfFile: file.path, encoding: .utf8) else { continue }
            let result = Compiler().compile(source)
            let diagnostics = TransitionContractValidator.validate(
                result.program.featureSets,
                against: spec,
                contractFilename: contract.lastPathComponent
            )
            guard !diagnostics.isEmpty else { continue }

            print("\(file.lastPathComponent):")
            for diagnostic in diagnostics {
                print("  \(formatLocation(diagnostic.location)) error: \(diagnostic.message)")
                for hint in diagnostic.hints {
                    print("    hint: \(hint)")
                }
            }
            print("  Found \(diagnostics.count) error(s) in \(file.lastPathComponent)")
            errorCount += diagnostics.count
        }
        return errorCount
    }

    /// Report, per contract route, whether the request body is held in memory
    /// or streamed (GitLab #477).
    ///
    /// This is the part of the body limit a programmer can act on *before*
    /// running anything: which routes are bounded by `x-aro-max-body`, which
    /// ones are not bounded at all because they never build the body, and
    /// where the contract and the code disagree about which is which.
    /// - Returns: the number of warnings emitted.
    // MARK: - Entry Point (GitLab #581)

    /// Report an application with no `Application-Start`, or more than one.
    ///
    /// The rule itself is `EntryPointCheck` in AROParser, so it is testable
    /// without driving the CLI; this formats its verdict.
    /// The first path component of `fileDirectory` below `root`, or `"."` when
    /// the file sits in `root` itself.
    static func group(of fileDirectory: URL, under root: URL) -> String {
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let fileComponents = fileDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents

        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents
        else { return "." }

        return fileComponents[rootComponents.count]
    }

    /// Apply `EntryPointCheck` to a directory without printing anything.
    ///
    /// `--recursive` needs the same verdict to decide whether a subdirectory
    /// is one application or a container of them, so the classification is
    /// shared rather than duplicated (GitLab #824).
    private func classifyEntryPoints(directory: URL, sourceFiles: [URL]) -> EntryPointCheck.Result {
        var declarations: [EntryPointCheck.Declaration] = []
        for file in sourceFiles {
            guard let source = try? String(contentsOfFile: file.path, encoding: .utf8) else { continue }
            // The group is the first path component under the directory being
            // checked, so several entry points in one subdirectory still read
            // as one application.
            //
            // Compared component-wise on symlink-resolved paths, because
            // trimming `directory.path + "/"` off the file's path as a string
            // breaks whenever the two spell the same directory differently.
            // On macOS `/var` is a symlink to `/private/var`, so a project
            // under `/var/folders/...` had the checked path trimmed out of the
            // *middle* of the resolved one and every group came back named
            // `privateAlpha` — one bogus group per application, which then
            // read as a directory of applications (GitLab #824).
            let fileDirectory = file.deletingLastPathComponent()
            let group = Self.group(of: fileDirectory, under: directory)
            for featureSet in Compiler().compile(source).program.featureSets {
                declarations.append(EntryPointCheck.Declaration(
                    name: featureSet.name,
                    activity: featureSet.businessActivity,
                    group: group
                ))
            }
        }
        return EntryPointCheck.classify(declarations)
    }

    private func reportEntryPoint(directory: URL, sourceFiles: [URL]) -> Int {
        switch classifyEntryPoints(directory: directory, sourceFiles: sourceFiles) {
        case .ok:
            return 0

        case .missing(let swapped):
            print("\nerror: No \(EntryPointCheck.entryPointName) feature set"
                  + " — the application has no entry point")
            if let swapped {
                print("  hint: (\(swapped.name): \(EntryPointCheck.entryPointName))"
                      + " has the name and the business activity the other way round")
                print("  hint: Write: (\(EntryPointCheck.entryPointName): \(swapped.name))")
            } else {
                print("  hint: Add: (\(EntryPointCheck.entryPointName): My App) { … }")
            }
            return 1

        case .separateApplications(let groups, let multipleWithin):
            // A directory of applications, not one application. `aro run` and
            // `aro build` both refuse this path and name a subdirectory to
            // point at; this used to print a note and exit 0, so a CI job
            // running `aro check $DIR` passed on a path that cannot run
            // (GitLab #824).
            print("\nerror: \(directory.lastPathComponent) contains \(groups.count)"
                  + " separate applications, not one")
            for group in groups.prefix(groupsToList) {
                print("  \(group)")
            }
            if groups.count > groupsToList {
                print("  … and \(groups.count - groupsToList) more")
            }
            if let first = groups.first {
                print("  hint: Check one of them: aro check \(directory.path)/\(first)")
            }
            print("  hint: Or check them all: aro check --recursive \(directory.path)")
            for group in multipleWithin {
                print("  note: \(group) declares more than one"
                      + " \(EntryPointCheck.entryPointName); checking it will say so")
            }
            return 1

        case .multiple(let starts):
            print("\nerror: \(starts.count) \(EntryPointCheck.entryPointName) feature sets"
                  + " — an application must have exactly one")
            for start in starts {
                print("  (\(EntryPointCheck.entryPointName): \(start.activity))")
            }
            return 1
        }
    }


    /// How many application names to print before summarising the rest.
    /// `aro check ./Examples` finds 109; listing them all buries the hint.
    private var groupsToList: Int { 10 }

    /// Check every application under `root` separately.
    ///
    /// "Separately" is the point: without it the command pools every `.aro`
    /// file under the path into one pseudo-application, so sibling
    /// applications appear to share feature sets, published symbols and
    /// entry points. Each directory here gets its own report and its own
    /// verdict, and a directory that is itself a container is recursed into.
    private func runRecursive(root: URL) throws {
        let applications = applicationDirectories(under: root)

        guard !applications.isEmpty else {
            // No subdirectory holds sources, so the path is one application
            // (or empty, which `checkApplication` reports).
            let (errors, _) = try checkApplication(at: root, isDirectory: true)
            if errors > 0 { Foundation.exit(1) }
            return
        }

        var failed: [String] = []
        for application in applications {
            print("\n=== \(application.path)")
            let (errors, _) = try checkApplication(at: application, isDirectory: true)
            if errors > 0 { failed.append(application.lastPathComponent) }
        }

        print()
        if failed.isEmpty {
            print("✅ \(applications.count) application(s) checked, no errors")
        } else {
            print("❌ \(failed.count) of \(applications.count) application(s) have errors:"
                  + " \(failed.joined(separator: ", "))")
            Foundation.exit(1)
        }
    }

    /// The application directories directly under `root`.
    ///
    /// A subdirectory counts when it holds `.aro` files anywhere beneath it.
    /// One that is itself a directory of applications — `ModulesExample`,
    /// whose three applications each live one level further down — expands to
    /// those, so `--recursive` reaches the same units `aro run` accepts.
    private func applicationDirectories(under root: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var found: [URL] = []
        for entry in contents.sorted(by: { $0.path < $1.path }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let sources = try? findSourceFiles(in: entry),
                  !sources.isEmpty
            else { continue }

            // Does this subdirectory hold applications of its own? Reuse the
            // rule rather than guessing from the layout.
            if case .separateApplications = classifyEntryPoints(directory: entry, sourceFiles: sources) {
                found.append(contentsOf: applicationDirectories(under: entry))
            } else {
                found.append(entry)
            }
        }
        return found
    }

    private func reportBodyPolicies(directory: URL, sourceFiles: [URL]) -> Int {
        let contract = ["openapi.yaml", "openapi.yml", "openapi.json"]
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let contract else { return 0 }

        guard let spec = try? OpenAPILoader.load(from: contract) else { return 0 }

        var featureSets: [FeatureSet] = []
        for file in sourceFiles {
            guard let source = try? String(contentsOfFile: file.path, encoding: .utf8) else { continue }
            let result = Compiler().compile(source)
            featureSets.append(contentsOf: result.program.featureSets)
        }
        guard !featureSets.isEmpty else { return 0 }

        let summaries = BodyMaterializationAnalyzer.analyze(featureSets)
        let byName = Dictionary(featureSets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        var lines: [String] = []
        var warningCount = 0

        for (path, item) in spec.paths.sorted(by: { $0.key < $1.key }) {
            for (method, operation) in item.allOperations {
                guard let operationId = operation.operationId else { continue }
                guard byName[operationId] != nil else { continue }

                let summary = summaries[operationId] ?? .conservative(operationId)
                // A route with no declared body whose feature set never mentions
                // one has nothing to report. Saying it "holds up to 1MB" would
                // be true and useless — the buffer is empty. A route that
                // streams (`materializes == false`) always has something to
                // say, declared body or not.
                let touchesBody = summary.statement != nil || !summary.materializes
                guard operation.requestBody != nil || touchesBody else { continue }

                let route = "\(method.uppercased()) \(path)"
                let declaredText = operation.xAroMaxBody
                let declared = operation.maxBodyBytes

                if let declaredText, declared == nil {
                    lines.append("  ⚠️  \(route): x-aro-max-body: \(declaredText) is not a size — using the default")
                    warningCount += 1
                    continue
                }

                if summary.materializes {
                    let limit = declared ?? RuntimeDefaults.maxMaterializedBody
                    var line = "  holds  \(route) — up to \(ByteSize.describe(limit)) in memory"
                    if let statement = summary.statement {
                        line += " (\(statement)"
                        if let number = summary.line { line += ", line \(number)" }
                        line += ")"
                    }
                    lines.append(line)

                    // A large declared limit on a route that reads its body is
                    // not a streaming route — it is that many bytes of memory
                    // per concurrent request, which is worth saying out loud.
                    if let declared, declared > 10_000_000 {
                        lines.append("  ⚠️  \(route): reads its body, so \(ByteSize.describe(declared)) is held in memory per request")
                        warningCount += 1
                    }
                } else {
                    lines.append("  streams \(route) — no limit applies, nothing is buffered")
                    if declaredText != nil {
                        lines.append("      note: x-aro-max-body is unused here; this route never builds the body")
                    }
                }
            }
        }

        guard !lines.isEmpty else { return warningCount }
        print()
        print("Request bodies:")
        for line in lines { print(line) }
        return warningCount
    }

    /// `--syntax` mode: validate a bare ARO snippet (no feature-set wrapper
    /// required). The snippet is wrapped in a throw-away feature set so the
    /// parser path is unchanged; diagnostics that fall inside the wrapper
    /// are filtered out and locations are shifted back to the user's
    /// coordinate space.
    private func runSyntaxOnly() throws {
        let source: String
        let label: String

        if path == "-" {
            label = "<stdin>"
            let data = FileHandle.standardInput.readDataToEndOfFile()
            source = String(data: data, encoding: .utf8) ?? ""
        } else if FileManager.default.fileExists(atPath: path) {
            label = URL(fileURLWithPath: path).lastPathComponent
            // The file exists but may be unreadable (permissions, non-UTF-8).
            // That's a real failure, not empty input — surfacing it as
            // "(empty input)" would send the user hunting for a syntax error
            // that isn't there. Report the read error and exit.
            do {
                source = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                FileHandle.standardError.write(Data("\(label): cannot read file: \(error)\n".utf8))
                Foundation.exit(1)
            }
        } else {
            // Treat the argument as the inline snippet itself.
            label = "<snippet>"
            source = path
        }

        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            print("\(label): (empty input)")
            print()
            print("❌ no source to check")
            Foundation.exit(1)
        }

        // If the snippet is already a full feature set (`(Name: Activity) { … }`),
        // wrapping it again creates an invalid nested feature-set. Detect and
        // check directly — same parser, no wrapper needed.
        let featureSetHeader = #"^\s*\(\s*[\w\- ]+:\s*[\w\- ]+(?:\s+takes\s+<[\w\-]+>)?\s*\)\s*(?:when\s+[^{]+)?\s*\{"#
        if trimmed.range(of: featureSetHeader, options: .regularExpression) != nil {
            try checkSnippetUnwrapped(source, label: label)
            return
        }

        // Build a wrapper that the parser accepts but won't add semantic
        // dependencies we'd then have to filter (an inert single-statement
        // body keeps the symbol table tiny).
        let header = "(SyntaxOnly_Check: Snippet) {\n"
        let footer = "\n    Return an <OK: status> for the <_snippet>.\n}\n"
        let wrapperLineOffset = header.filter { $0 == "\n" }.count
        let wrapped = header + source + footer

        let compiler = Compiler()
        let result = compiler.compile(wrapped)

        // Diagnostics on lines <= wrapperLineOffset came from `header`
        // itself (impossible — header is known-valid — but defensive).
        // Anything past `wrapperLineOffset + sourceLines` came from the
        // footer / wrapper Return — skip those too.
        let sourceLineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
        let snippetUpperBound = wrapperLineOffset + sourceLineCount

        // We only care about syntax: filter out "External dependency" and
        // "defined but not used" warnings, which are semantic-analyser
        // artefacts of the dummy wrapper, not real issues in the snippet.
        func isSemanticNoise(_ message: String) -> Bool {
            return message.hasPrefix("External dependency")
                || message.contains("is defined but never used")
                || message.contains("not published by any feature set")
        }

        var realErrors = 0
        var realWarnings = 0
        var printedHeader = false

        func printDiag(_ d: AROParser.Diagnostic, severity: String) {
            if !printedHeader {
                print("\(label):")
                printedHeader = true
            }
            let loc = d.location.map { "\($0.line - wrapperLineOffset):\($0.column):" } ?? ""
            print("  \(loc) \(severity): \(d.message)")
            for hint in d.hints {
                print("    hint: \(hint)")
            }
        }

        for d in result.diagnostics {
            // Skip diagnostics that point at the wrapper.
            if let loc = d.location, loc.line <= wrapperLineOffset || loc.line > snippetUpperBound {
                continue
            }
            if isSemanticNoise(d.message) {
                continue
            }
            switch d.severity {
            case .error:
                printDiag(d, severity: "error")
                realErrors += 1
            case .warning:
                if warnings {
                    printDiag(d, severity: "warning")
                }
                realWarnings += 1
            default:
                continue
            }
        }

        if realErrors > 0 || (warnings && realWarnings > 0) {
            print("  Found \(realErrors) error(s)\(realWarnings > 0 && warnings ? ", \(realWarnings) warning(s)" : "") in \(label)")
        }

        print()
        if realErrors == 0 && realWarnings == 0 {
            print("✅ No syntax issues in \(label)")
        } else {
            if realErrors > 0 {
                print("❌ \(realErrors) syntax error(s)")
            }
            if realWarnings > 0 && warnings {
                print("⚠️  \(realWarnings) warning(s)")
            }
        }
        if realErrors > 0 {
            Foundation.exit(1)
        }
    }

    /// `--syntax` mode for snippets that already contain a feature-set
    /// header — no wrapper, just run the parser and report.
    private func checkSnippetUnwrapped(_ source: String, label: String) throws {
        let compiler = Compiler()
        let result = compiler.compile(source)

        func isSemanticNoise(_ message: String) -> Bool {
            return message.hasPrefix("External dependency")
                || message.contains("is defined but never used")
                || message.contains("not published by any feature set")
        }

        var realErrors = 0
        var realWarnings = 0
        var printedHeader = false

        for d in result.diagnostics {
            if isSemanticNoise(d.message) { continue }
            switch d.severity {
            case .error:
                if !printedHeader { print("\(label):"); printedHeader = true }
                let loc = d.location.map { "\($0.line):\($0.column):" } ?? ""
                print("  \(loc) error: \(d.message)")
                for h in d.hints { print("    hint: \(h)") }
                realErrors += 1
            case .warning:
                realWarnings += 1
                if warnings {
                    if !printedHeader { print("\(label):"); printedHeader = true }
                    let loc = d.location.map { "\($0.line):\($0.column):" } ?? ""
                    print("  \(loc) warning: \(d.message)")
                    for h in d.hints { print("    hint: \(h)") }
                }
            default:
                continue
            }
        }

        print()
        if realErrors == 0 && realWarnings == 0 {
            print("✅ No syntax issues in \(label)")
        } else {
            if realErrors > 0 { print("❌ \(realErrors) syntax error(s)") }
            if realWarnings > 0 && warnings { print("⚠️  \(realWarnings) warning(s)") }
        }
        if realErrors > 0 { Foundation.exit(1) }
    }

    private func findSourceFiles(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sourceFiles: [URL] = []

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "aro" {
                sourceFiles.append(fileURL)
            }
        }

        return sourceFiles.sorted { $0.path < $1.path }
    }

    /// Event types handled anywhere in the application.
    ///
    /// Parse-only: the business activity is on the feature-set header, so no
    /// semantic analysis is needed, and a file that does not parse simply
    /// contributes nothing — its own errors are reported when it is checked.
    private func handledEventTypes(in files: [URL]) -> Set<String> {
        var handled: Set<String> = []
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8),
                  let tokens = try? Lexer.tokenize(source),
                  let program = try? Parser(tokens: tokens).parse()
            else { continue }
            handled.formUnion(EventAnalyzer.handledEventTypes(in: program))
        }
        return handled
    }

    private func checkFile(
        _ file: URL,
        handledEvents: Set<String> = [],
        declaredActions: UserActionRegistry? = nil
    ) throws -> (errors: Int, warnings: Int) {
        let source = try String(contentsOf: file, encoding: .utf8)
        let compiler = Compiler()
        let result = compiler.compile(
            source,
            externallyHandledEvents: handledEvents,
            declaredUserActions: declaredActions
        )

        let errors = result.diagnostics.filter { $0.severity == .error }
        let warningDiags = result.diagnostics.filter { $0.severity == .warning }

        if !errors.isEmpty || (!warningDiags.isEmpty && warnings) {
            print("\(file.lastPathComponent):")

            for error in errors {
                let location = formatLocation(error.location)
                print("  \(location) error: \(error.message)")

                for hint in error.hints {
                    print("    hint: \(hint)")
                }
            }

            if warnings {
                for warning in warningDiags {
                    let location = formatLocation(warning.location)
                    print("  \(location) warning: \(warning.message)")

                    for hint in warning.hints {
                        print("    hint: \(hint)")
                    }
                }
            }

            // Per-file summary
            var parts: [String] = []
            if !errors.isEmpty { parts.append("\(errors.count) error(s)") }
            if !warningDiags.isEmpty && warnings { parts.append("\(warningDiags.count) warning(s)") }
            print("  Found \(parts.joined(separator: ", ")) in \(file.lastPathComponent)")
        } else if verbose {
            print("\(file.lastPathComponent): OK")
        }

        return (errors.count, warningDiags.count)
    }

    private func formatLocation(_ location: SourceLocation?) -> String {
        guard let loc = location else { return "" }
        return "\(loc.line):\(loc.column):"
    }
}

// MARK: - Plugin Check

/// Check plugin compatibility with the current ARO version
///
/// Usage: aro check plugins [--directory <path>] [--verbose]
struct PluginCheckSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugins",
        abstract: "Check plugin compatibility with the current ARO version"
    )

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    @Flag(name: .long, help: "Show details for each plugin")
    var verbose: Bool = false

    func run() throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let pm = PackageManager(applicationDirectory: appDir)
        let currentVersion = AROVersion.version

        print("🔍 Checking plugins against ARO \(currentVersion)...")
        print("")

        var hasIssues = false

        // 1. ARO version compatibility (top-level + per-action since)
        let results = try pm.checkAROVersionCompatibility(currentAROVersion: currentVersion)
        let incompatible = results.filter { !$0.isCompatible }

        if incompatible.isEmpty {
            print("✅ All plugins are compatible with ARO \(currentVersion)")
        } else {
            hasIssues = true
            print("❌ Incompatible plugins:")
            for result in incompatible.sorted(by: { $0.pluginName < $1.pluginName }) {
                if let constraint = result.pluginConstraint {
                    print("   • \(result.pluginName) requires ARO \(constraint)")
                }
                for (actionName, since) in result.incompatibleActions {
                    print("   • \(result.pluginName)/\(actionName) requires ARO >=\(since)")
                }
            }
        }

        // 2. Missing plugin dependencies
        let missingDeps = try pm.checkDependencies()
        if !missingDeps.isEmpty {
            hasIssues = true
            print("")
            print("📦 Missing dependencies:")
            for (plugin, deps) in missingDeps.sorted(by: { $0.key < $1.key }) {
                print("   • \(plugin) requires: \(deps.joined(separator: ", "))")
            }
        }

        // 3. Lock file verification
        let mismatches = try pm.verifyLockFile()
        if !mismatches.isEmpty {
            hasIssues = true
            print("")
            print("🔒 Lock file mismatches (run 'aro plugins update' to fix):")
            for name in mismatches {
                print("   • \(name)")
            }
        } else if pm.lockFile.exists {
            print("🔒 Lock file verified — all commits match")
        }

        // 4. Verbose: per-plugin details
        if verbose {
            let plugins = try pm.list()
            if !plugins.isEmpty {
                print("")
                print("Plugin details:")
                for plugin in plugins {
                    let constraint = plugin.manifest.aroVersion ?? "(any)"
                    let lock = pm.lockFile.load().entry(for: plugin.manifest.name)
                    let commit = lock?.commit.map { String($0.prefix(7)) } ?? "not locked"
                    print("   \(plugin.manifest.name) v\(plugin.manifest.version)")
                    print("     aro-version: \(constraint)")
                    print("     commit:      \(commit)")
                    if let system = plugin.manifest.system, !system.isEmpty {
                        print("     system:      \(system.joined(separator: ", "))")
                    }
                    // Show per-action since values
                    let actions = plugin.manifest.provides.flatMap { $0.actions ?? [] }.filter { $0.since != nil }
                    if !actions.isEmpty {
                        print("     actions:")
                        for action in actions {
                            print("       \(action.name) (since \(action.since!))")
                        }
                    }
                }
            }
        }

        print("")
        if hasIssues {
            throw ExitCode.failure
        } else {
            print("✅ All checks passed")
        }
    }
}
