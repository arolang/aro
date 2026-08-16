// ============================================================
// SigningSettingsTab.swift
// SOLARO — Settings → Signing (#268)
// ============================================================
//
// Picks the Apple Developer Team ID used to sign and notarize a
// release build. The list comes from the login keychain, so the
// normal path is "choose your certificate" rather than "go find a
// ten-character string in your Apple Developer account".
//
// Manual entry stays available: a CI-only Team ID has no local
// certificate to pick.

import SwiftUI
import AppKit

struct SigningSettingsTab: View {
    @State private var settings = SigningSettings()
    @State private var manualEntry = false
    @State private var copiedExport = false

    var body: some View {
        Form {
            Section {
                if settings.identities.isEmpty {
                    Label(
                        "No codesigning certificates in the login keychain.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    Text("Install a Developer ID Application certificate from your Apple Developer account, or enter the Team ID by hand below for CI-only signing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Certificate", selection: identityBinding) {
                        Text("None").tag("")
                        ForEach(settings.identities) { identity in
                            Text(identity.displayName).tag(identity.sha1)
                        }
                    }
                    if let selected = settings.selectedIdentity, !selected.canNotarize {
                        Label(
                            "\(selected.kind) certificates can sign but cannot notarize — Apple's notary rejects them after upload. Release builds need a Developer ID Application certificate.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                HStack {
                    Button {
                        settings.rescan()
                    } label: {
                        Label("Rescan keychain", systemImage: "arrow.clockwise")
                    }
                    .disabled(settings.isScanning)
                    Spacer()
                    Toggle("Enter Team ID manually", isOn: $manualEntry)
                        .toggleStyle(.checkbox)
                }
            } header: {
                Text("Signing certificate")
            } footer: {
                Text("Read from `security find-identity -v -p codesigning`. Nothing leaves this machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if manualEntry || settings.identities.isEmpty {
                    TextField("Team ID", text: teamIDBinding, prompt: Text("AB12CD34EF"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    HStack {
                        Text(settings.teamID.isEmpty ? "Not set" : settings.teamID)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(settings.teamID.isEmpty
                                             ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(.primary))
                        Spacer()
                    }
                }
                if settings.lacksNotarizingCertificate {
                    Label(
                        "No Developer ID Application certificate on this machine matches \(settings.teamID). Signing here will not be notarizable.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Team ID")
            } footer: {
                Text("Used by `Scripts/package-solaro-dmg.sh` and by `xcrun notarytool --team-id` in the release workflow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(exportLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(copiedExport ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(exportLine, forType: .string)
                        copiedExport = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copiedExport = false
                        }
                    }
                    .disabled(settings.teamID.isEmpty)
                }
            } header: {
                Text("For CI")
            } footer: {
                Text("Set this as APPLE_TEAM_ID alongside APPLE_ID and APPLE_APP_PASSWORD in the release pipeline's secrets. The certificate itself is never read from here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.rescan() }
    }

    private var exportLine: String {
        "APPLE_TEAM_ID=\(settings.teamID.isEmpty ? "…" : settings.teamID)"
    }

    private var identityBinding: Binding<String> {
        Binding(
            get: { settings.identitySHA1 },
            set: { sha1 in
                if let match = settings.identities.first(where: { $0.sha1 == sha1 }) {
                    settings.select(match)
                } else {
                    settings.identitySHA1 = ""
                }
            }
        )
    }

    private var teamIDBinding: Binding<String> {
        Binding(
            get: { settings.teamID },
            set: { settings.teamID = $0 }
        )
    }
}
