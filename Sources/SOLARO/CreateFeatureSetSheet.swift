// ============================================================
// CreateFeatureSetSheet.swift
// SOLARO — "Create new Feature Set" dialog (#?)
// ============================================================
//
// Right-click on a blank area of the canvas now offers two
// menu items: the existing "Auto Layout" and a new
// "Create new Feature Set…". Picking the second one opens this
// dialog, the user fills in name + business activity + an
// optional `when` guard + (for Action feature sets) a `takes`
// parameter, and CenterPane appends the resulting source to the
// currently-open `.aro` file.
//
// The dialog deliberately produces an *empty* body — the user
// then double-clicks into it on the canvas (or types in the
// editor) to fill in statements. Keeping the generated source
// minimal avoids surprising the user with placeholder verbs
// they then have to delete.

import SwiftUI

/// Description of the FS the user is creating — mirrors the
/// fields `Sources/AROParser/AST.swift` declares on `FeatureSet`.
/// Held in `@State` while the sheet is up; on Create the parent
/// renders it into source via `FeatureSetTemplate.render`.
struct NewFeatureSetDraft: Equatable {
    var name: String = ""
    var businessActivity: String = ""
    /// Optional `when <expr>` guard between the header and the
    /// opening brace.
    var whenCondition: String = ""
    /// Optional `takes <name>` clause — only emitted when the
    /// business activity is "Action" (the user-defined-action
    /// sugar from ARO-0081). The dialog hides this row otherwise.
    var takesField: String = ""
    /// Optional type annotation for the takes field
    /// (e.g. "Integer").
    var takesType: String = ""

    var isReadyToCreate: Bool {
        !name.trimmed.isEmpty && !businessActivity.trimmed.isEmpty
    }

    var isAction: Bool {
        businessActivity.trimmed.lowercased() == "action"
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Renders a `NewFeatureSetDraft` into a minimal valid
/// AROStatement-free feature-set block. The result is appended
/// verbatim to the file by CenterPane.
enum FeatureSetTemplate {

    static func render(_ draft: NewFeatureSetDraft) -> String {
        var header = "(\(draft.name.trimmed): \(draft.businessActivity.trimmed))"
        if draft.isAction, !draft.takesField.trimmed.isEmpty {
            let f = draft.takesField.trimmed
            if !draft.takesType.trimmed.isEmpty {
                header += " takes <\(f): \(draft.takesType.trimmed)>"
            } else {
                header += " takes <\(f)>"
            }
        }
        let whenExpr = draft.whenCondition.trimmed
        if !whenExpr.isEmpty {
            header += " when \(whenExpr)"
        }
        return """
        \(header) {
        }
        """
    }
}

struct CreateFeatureSetSheet: View {
    let onCancel: () -> Void
    let onCreate: (NewFeatureSetDraft) -> Void

    @State private var draft = NewFeatureSetDraft()
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            header
            Divider()
            form
            footer
        }
        .padding(SolaroSpace.l)
        .frame(width: 480)
        .background(SolaroColor.surface)
        .onAppear { nameFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Create new Feature Set")
                .font(SolaroFont.bodyBold)
                .foregroundStyle(SolaroColor.textPrimary)
            Text("Adds an empty feature set to the open .aro file. You can fill in statements after it's created.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            field(label: "NAME",
                  placeholder: "listUsers, handleRoot, length-of-hello, …",
                  text: $draft.name)
                .focused($nameFocused)
            field(label: "BUSINESS ACTIVITY",
                  placeholder: "User API, HTTP Server API, String Utils Test, Action, …",
                  text: $draft.businessActivity)
            field(label: "WHEN (optional)",
                  placeholder: "",
                  text: $draft.whenCondition)
            if draft.isAction {
                field(label: "TAKES PARAMETER (optional)",
                      placeholder: "input",
                      text: $draft.takesField)
                field(label: "TAKES TYPE (optional)",
                      placeholder: "String, Integer, …",
                      text: $draft.takesType)
            }
            preview
        }
    }

    private func field(label: String,
                       placeholder: String,
                       text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(SolaroFont.caption)
                .tracking(1)
                .foregroundStyle(SolaroColor.textTertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PREVIEW")
                .font(SolaroFont.caption)
                .tracking(1)
                .foregroundStyle(SolaroColor.textTertiary)
            Text(FeatureSetTemplate.render(draft))
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SolaroSpace.s)
                .background(
                    RoundedRectangle(cornerRadius: SolaroRadius.s,
                                     style: .continuous)
                        .fill(SolaroColor.surfaceRaised.opacity(0.6))
                )
                .textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Create") { onCreate(draft) }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isReadyToCreate)
        }
    }
}
