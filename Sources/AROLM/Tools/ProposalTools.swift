// ============================================================
// ProposalTools.swift
// AROLM - tools for listing and reading ARO proposals
// ============================================================

import Foundation

/// Tools that expose the `Proposals/` directory so the model can cite the
/// authoritative specification rather than guessing.
public enum ProposalTools {

    /// Locate the `Proposals/` directory. Search order:
    ///   1. A `Proposals/` folder in the working directory
    ///   2. A `Proposals/` folder in any parent directory
    ///   3. `/opt/homebrew/share/aro/Proposals`
    ///   4. `/usr/local/share/aro/Proposals`
    ///   5. `~/.aro/Proposals`
    private static func proposalsRoot(from cwd: URL) -> URL? {
        let fm = FileManager.default
        var dir = cwd
        while true {
            let candidate = dir.appendingPathComponent("Proposals")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        let fallbacks = [
            "/opt/homebrew/share/aro/Proposals",
            "/usr/local/share/aro/Proposals",
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".aro/Proposals").path
        ]
        for p in fallbacks where fm.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    public static func listProposals(cwd: URL) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
        return LMToolDescriptor(
            name: "list_proposals",
            description: "List all ARO language proposals by filename.",
            parameters: params
        ) { _ in
            guard let root = proposalsRoot(from: cwd) else {
                return "no Proposals directory found"
            }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return files.sorted().filter { $0.hasSuffix(".md") }.joined(separator: "\n")
        }
    }

    public static func readProposal(cwd: URL) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("Proposal number (e.g. '0001') or filename prefix")
                ])
            ]),
            "required": .array([.string("id")])
        ])
        return LMToolDescriptor(
            name: "read_proposal",
            description: "Read an ARO language proposal by number or filename prefix.",
            parameters: params
        ) { args in
            guard let id = args["id"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'id'")
            }
            guard let root = proposalsRoot(from: cwd) else {
                return "no Proposals directory found"
            }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            let needle = id.hasPrefix("ARO-") ? id : "ARO-\(id)"
            guard let match = files.first(where: { $0.hasPrefix(needle) }) else {
                return "no proposal matching '\(id)'"
            }
            let text = try String(contentsOf: root.appendingPathComponent(match), encoding: .utf8)
            return text
        }
    }

    public static func all(cwd: URL) -> [LMToolDescriptor] {
        [listProposals(cwd: cwd), readProposal(cwd: cwd)]
    }
}
