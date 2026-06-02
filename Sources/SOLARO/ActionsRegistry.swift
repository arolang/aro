// ============================================================
// ActionsRegistry.swift
// SOLARO — `aro actions` listing for the right-pane Actions tab
// ============================================================
//
// Runs `aro actions` once per project open, parses the table-style
// stdout into typed records, and caches them. The right-pane
// Actions tab consumes the cached list; rows are drag sources
// that provide an ARO statement template — dropping into the
// text editor inserts the template at the cursor.

import Foundation

/// One row from `aro actions`.
struct ActionInfo: Identifiable, Equatable, Hashable {
    let id: String                   // verb (unique)
    let verb: String
    let role: Role
    let prepositions: [String]
    /// `true` if the action came from an installed plugin (sourced
    /// from the project's Plugins/ dir) rather than the built-in
    /// registry. Used to group rows in the UI.
    let isPlugin: Bool

    enum Role: String, Equatable, Hashable {
        case request, own, response, export, server, unknown

        init(raw: String) {
            switch raw.lowercased() {
            case "request":  self = .request
            case "own":      self = .own
            case "response": self = .response
            case "export":   self = .export
            case "server":   self = .server
            default:         self = .unknown
            }
        }

        /// Sort order: request → own → response → export → server →
        /// unknown. Mirrors data-flow direction.
        var sortKey: Int {
            switch self {
            case .request:  return 0
            case .own:      return 1
            case .response: return 2
            case .export:   return 3
            case .server:   return 4
            case .unknown:  return 5
            }
        }

        var label: String {
            switch self {
            case .request:  return "REQUEST"
            case .own:      return "OWN"
            case .response: return "RESPONSE"
            case .export:   return "EXPORT"
            case .server:   return "SERVER"
            case .unknown:  return "OTHER"
            }
        }
    }

    /// Build a one-line ARO statement template for this action,
    /// using the first preposition as the primary slot. Used as
    /// the payload of the drag-and-drop on the Actions list.
    var statementTemplate: String {
        let preposition = prepositions.first ?? "with"
        let resultSlot = "<result>"
        let inputSlot = "<input>"
        switch role {
        case .request:
            return "\(verb) the \(resultSlot) from the \(inputSlot)."
        case .own:
            return "\(verb) the \(resultSlot) \(preposition) the \(inputSlot)."
        case .response:
            return "\(verb) an <OK: status> \(preposition) the \(resultSlot)."
        case .export:
            return "\(verb) the \(resultSlot) \(preposition) the \(inputSlot)."
        case .server:
            return "\(verb) the \(resultSlot) \(preposition) the \(inputSlot)."
        case .unknown:
            return "\(verb) the \(resultSlot) \(preposition) the \(inputSlot)."
        }
    }
}

@MainActor
@Observable
final class ActionsRegistry {
    private(set) var actions: [ActionInfo] = []
    private(set) var lastError: String?
    private(set) var isLoading: Bool = false

    /// Run `aro actions` against the project, parse the result.
    /// Idempotent — call from openFile() etc.
    func reload(for project: Project) {
        isLoading = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            let (list, error) = await Self.runAroActions(project: project)
            await MainActor.run {
                if let error {
                    self.lastError = error
                } else {
                    self.actions = list
                }
                self.isLoading = false
            }
        }
    }

    /// Spawn `aro actions` and parse the table output. Run off-
    /// main-actor because Process.run + readDataToEndOfFile block.
    /// Returns the parsed list plus an optional error message.
    nonisolated static func runAroActions(
        project: Project
    ) async -> (actions: [ActionInfo], error: String?) {
        let aro = await MainActor.run {
            ConsoleProcess.resolveAroBinary(near: project)
        }
        let task = Process()
        if aro == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["aro", "actions", "-d", project.rootPath.path]
        } else {
            task.executableURL = URL(fileURLWithPath: aro)
            task.arguments = ["actions", "-d", project.rootPath.path]
        }
        task.currentDirectoryURL = project.rootPath
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let err = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? "aro actions exited with status \(task.terminationStatus)"
                return ([], err)
            }
            let text = String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return (parse(text), nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    /// Parse the table-formatted output of `aro actions`. Section
    /// headers ("Built-in Actions:", "Plugin Actions:") flip the
    /// isPlugin flag; data rows follow `<Name>  <Role>  <Prepositions>`.
    nonisolated static func parse(_ text: String) -> [ActionInfo] {
        var out: [ActionInfo] = []
        var seen: Set<String> = []
        var isPlugin = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Section markers.
            let lower = trimmed.lowercased()
            if lower.hasPrefix("built-in actions") {
                isPlugin = false
                continue
            }
            if lower.hasPrefix("plugin actions") {
                isPlugin = true
                continue
            }
            // Header / separator rows.
            if lower.hasPrefix("name") || trimmed.hasPrefix("──") {
                continue
            }
            // Column split: name, role, then prepositions (comma-
            // separated). Whitespace-split is good enough.
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                .map { String($0) }
            guard parts.count >= 2 else { continue }
            let verb = parts[0]
            // Verb starts with a capital letter; lines like "See"
            // or hint text accidentally squeezing through fail here.
            guard verb.first?.isLetter == true,
                  verb.first?.isUppercase == true
            else { continue }
            if seen.contains(verb) { continue }
            seen.insert(verb)
            let role = ActionInfo.Role(raw: parts[1])
            let prepositions = parts.count > 2
                ? parts[2...].joined(separator: " ")
                    .replacingOccurrences(of: ",", with: " ")
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .map(String.init)
                : []
            out.append(ActionInfo(
                id: verb,
                verb: verb,
                role: role,
                prepositions: prepositions,
                isPlugin: isPlugin
            ))
        }
        return out.sorted { lhs, rhs in
            if lhs.role.sortKey != rhs.role.sortKey {
                return lhs.role.sortKey < rhs.role.sortKey
            }
            return lhs.verb < rhs.verb
        }
    }
}
