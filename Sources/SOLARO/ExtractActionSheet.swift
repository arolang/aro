// ============================================================
// ExtractActionSheet.swift
// SOLARO — "Extract as Action" refactor (#233 §3)
// ============================================================
//
// Right-clicking a canvas statement → Extract as Action… opens
// this sheet. The user picks a name; we splice the picked
// statement out of its feature set and create a new
// `(<Name>: Action)` feature set containing the same statement.
// The original call site is rewritten to invoke the new action.

import SwiftUI
import AROParser

@MainActor
@Observable
final class ExtractActionState {
    var node: CanvasNode?
    var sourceURL: URL?
    var name: String = ""
}

struct ExtractActionSheet: View {
    @Bindable var state: ExtractActionState
    let onCancel: () -> Void
    let onConfirm: (CanvasNode, URL, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            HStack {
                Image(systemName: "function")
                    .foregroundStyle(SolaroColor.accent)
                Text("Extract as Action")
                    .font(SolaroFont.toolbarTitle)
                Spacer()
            }
            if let node = state.node {
                Text("Selected statement")
                    .font(SolaroFont.sectionTitle)
                    .tracking(2)
                    .foregroundStyle(SolaroColor.textTertiary)
                Text(statementPreview(for: node))
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .textSelection(.enabled)
                    .padding(SolaroSpace.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SolaroColor.backdrop)
                    .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
            }
            Text("New action name")
                .font(SolaroFont.sectionTitle)
                .tracking(2)
                .foregroundStyle(SolaroColor.textTertiary)
            TextField("MyAction", text: $state.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirm() }
            Text("The selected statement moves into a new `(<Name>: Action)` feature set. The call site here becomes `Application.<Name> …`.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Extract", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValidName(state.name) || state.node == nil)
            }
        }
        .padding(SolaroSpace.l)
        .frame(minWidth: 480)
        .background(SolaroColor.surface)
    }

    private func confirm() {
        guard let node = state.node,
              let url = state.sourceURL,
              isValidName(state.name)
        else { return }
        onConfirm(node, url, state.name.trimmingCharacters(in: .whitespaces))
    }

    private func statementPreview(for node: CanvasNode) -> String {
        node.summary
    }

    /// Conventional ARO names are PascalCase — letters + digits,
    /// starting with a letter. Reject anything that would confuse
    /// the parser at the call site.
    private func isValidName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first.isLetter else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

/// Pure textual splice driver — keep all the source-mutation
/// logic in one testable place. Given a source file and the
/// canvas node clicked, it returns the new source.
enum ExtractActionRefactor {
    struct Result {
        let newSource: String
        let createdFeatureSetName: String
        let newCallSiteLine: Int
    }

    static func apply(
        source: String,
        node: CanvasNode,
        actionName: String
    ) -> Result? {
        let lines = source.components(separatedBy: "\n")
        guard
            let startIdx = lines.indices.first(where: { i in
                i + 1 == node.lineHint
            })
        else { return nil }
        let lineIndex = startIdx
        guard lineIndex < lines.count else { return nil }
        let originalLine = lines[lineIndex]
        let trimmed = originalLine.trimmingCharacters(in: .whitespaces)
        let indent = String(originalLine.prefix { $0 == " " || $0 == "\t" })

        // Build the call-site rewrite: `Application.<Name> the
        // <result> from <object>.` — falls back to a bare call
        // if there's no object so it stays valid for actions like
        // `Application.Cleanup the <state>.`.
        let callSite: String = {
            var pieces = ["Application.\(actionName)"]
            if let result = node.resultName, !result.isEmpty {
                pieces.append("the <\(result)>")
            }
            if let object = node.objectName, !object.isEmpty {
                let prep = node.objectPreposition ?? "from"
                pieces.append("\(prep) the <\(object)>")
            }
            return indent + pieces.joined(separator: " ") + "."
        }()

        // Build the new feature set body. We re-emit the original
        // statement and a Return so the action exposes its result
        // to callers. Indent two levels deep so it reads cleanly.
        let bodyStatement = "    " + trimmed
        let returnStatement: String? = {
            guard let result = node.resultName, !result.isEmpty else { return nil }
            return "    Return an <OK: status> with <\(result)>."
        }()
        var bodyLines = [bodyStatement]
        if let ret = returnStatement { bodyLines.append(ret) }
        let featureSet = """

        (\(actionName): Action) {
        \(bodyLines.joined(separator: "\n"))
        }
        """

        var newLines = lines
        newLines[lineIndex] = callSite
        let newSource = newLines.joined(separator: "\n") + featureSet + "\n"
        let newCallSiteLine = lineIndex + 1

        return Result(
            newSource: newSource,
            createdFeatureSetName: actionName,
            newCallSiteLine: newCallSiteLine
        )
    }
}
