// ============================================================
// ProposalTools.swift
// AROAsk - tools for browsing ARO language proposals
// ============================================================

import Foundation

public enum ProposalTools {
    public static func all(cwd: URL) -> [AskToolDescriptor] {
        [listProposals(cwd: cwd), readProposal(cwd: cwd)]
    }

    // MARK: - list_proposals

    private static func listProposals(cwd: URL) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "list_proposals",
            description: "List all ARO language proposals with their number and title.",
            schema: .empty
        ) { _ in
            let proposalsDir = cwd.appendingPathComponent("Proposals")
            let fm = FileManager.default

            guard fm.fileExists(atPath: proposalsDir.path) else {
                throw AskToolError.executionFailed("Proposals directory not found at \(proposalsDir.path)")
            }

            let contents = try fm.contentsOfDirectory(
                at: proposalsDir,
                includingPropertiesForKeys: nil
            )

            let mdFiles = contents
                .filter { $0.pathExtension == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            if mdFiles.isEmpty {
                return "No proposals found."
            }

            var lines: [String] = []
            for file in mdFiles {
                let title = extractTitle(from: file)
                let name = file.lastPathComponent
                lines.append("- \(name): \(title ?? "(no title)")")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - read_proposal

    private static func readProposal(cwd: URL) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "read_proposal",
            description: "Read the full text of a specific ARO language proposal by number (e.g. \"0001\" or \"ARO-0001\").",
            schema: ToolParameterSchema([
                .required("number", .string, "Proposal number, e.g. \"0001\" or \"ARO-0001\""),
            ])
        ) { args in
            let number = try args.requireString("number")

            // Normalize: strip "ARO-" prefix if present
            let digits: String
            if number.uppercased().hasPrefix("ARO-") {
                digits = String(number.dropFirst(4))
            } else {
                digits = number
            }

            let proposalsDir = cwd.appendingPathComponent("Proposals")
            let fm = FileManager.default

            guard fm.fileExists(atPath: proposalsDir.path) else {
                throw AskToolError.executionFailed("Proposals directory not found at \(proposalsDir.path)")
            }

            let contents = try fm.contentsOfDirectory(
                at: proposalsDir,
                includingPropertiesForKeys: nil
            )

            let prefix = "ARO-\(digits)"
            guard let match = contents.first(where: {
                $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "md"
            }) else {
                throw AskToolError.executionFailed("No proposal found matching '\(prefix)'")
            }

            return try String(contentsOf: match, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    /// Extract the first markdown heading (# ...) from a file.
    private static func extractTitle(from url: URL) -> String? {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2))
            }
        }
        return nil
    }
}
