// ============================================================
// BuildSheet.swift
// SOLARO — ask what kind of binary, then build it (#763)
// ============================================================
//
// Two controls, because `aro build` has two choices a person actually
// makes per build. Everything else it takes is derived.
//
// The choices are remembered, so the second build is one Return press.

import SwiftUI

struct BuildSheet: View {
    let projectName: String
    /// Called with the chosen options when the user confirms.
    let onBuild: (BuildOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options = BuildOptions.remembered()

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            Text("Build \(projectName)")
                .font(SolaroFont.toolbarTitle)

            Picker("Linking", selection: $options.linkage) {
                ForEach(BuildLinkage.allCases) { linkage in
                    Text(linkage.displayName).tag(linkage)
                }
            }
            .pickerStyle(.radioGroup)
            Text(options.linkage.detail)
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)

            Toggle("Optimize", isOn: $options.optimize)
            Text("Slower to build, faster to run. What a release binary wants.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)

            Divider()

            // The command, so the user can run the same thing in a
            // terminal or put it in a script. This is also what the
            // console echoes when the build starts.
            Text(options.commandLine(projectName: projectName))
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textSecondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Build") {
                    options.remember()
                    onBuild(options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SolaroSpace.l)
        .frame(width: 420)
    }
}
