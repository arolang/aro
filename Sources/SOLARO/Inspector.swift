// ============================================================
// Inspector.swift
// SOLARO — right inspector pane (Phase 6)
// ============================================================
//
// Wireframe target: note 8467 figure 3.
//
// Three stacked sections inside the inspector column:
//
//   ┌──────────────────────────────────────┐
//   │ File header                          │
//   │  ▸ users.aro · 3 feature sets · ok   │
//   ├──────────────────────────────────────┤
//   │ Feature sets                         │
//   │  ┃ Application-Start: …              │  ← role-tinted stripe
//   │  ┃   • Log "Hi" to <console>         │     on every card
//   │  ┃   • Return <OK: status> with …    │
//   │  ┃ listUsers: User API               │
//   │  ┃   • Retrieve <users> from …       │
//   ├──────────────────────────────────────┤
//   │ Deploy & live                        │
//   │  runtime 0.10.3 · no events yet      │
//   └──────────────────────────────────────┘

import SwiftUI
import AROParser
import AROVersion

struct InspectorPaneView: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SolaroSpace.m) {
                fileHeader
                featureSetSection
                deployRail
                Spacer(minLength: SolaroSpace.l)
            }
            .padding(.horizontal, SolaroSpace.m)
            .padding(.top, SolaroSpace.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SolaroColor.surface)
    }

    // MARK: - File header

    private var fileHeader: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            Text("INSPECTOR")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)

            if let url = controller.currentFile {
                VStack(alignment: .leading, spacing: SolaroSpace.xs) {
                    Text(url.lastPathComponent)
                        .font(SolaroFont.bodyBold)
                        .foregroundStyle(SolaroColor.textPrimary)
                    parseStatus
                }
                .padding(SolaroSpace.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .solaroCard()
            } else {
                Text("No file open.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var parseStatus: some View {
        if let error = controller.currentParseError {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(SolaroColor.stateError)
                Text("Parse failed")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.stateError)
            }
            Text(error)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.stateError.opacity(0.85))
                .lineLimit(4)
                .padding(.top, 2)
        } else if let program = controller.currentProgram {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(SolaroColor.stateOK)
                Text("\(program.featureSets.count) feature set\(program.featureSets.count == 1 ? "" : "s") · ok")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textSecondary)
            }
        } else {
            Text("Parsing…")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
    }

    // MARK: - Feature sets

    @ViewBuilder
    private var featureSetSection: some View {
        if let program = controller.currentProgram, !program.featureSets.isEmpty {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                Text("FEATURE SETS")
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .tracking(2)
                ForEach(program.featureSets, id: \.name) { fs in
                    FeatureSetCard(fs: fs)
                }
            }
            .padding(.top, SolaroSpace.s)
        }
    }

    // MARK: - Deploy rail

    private var deployRail: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            Text("DEPLOY & LIVE")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                HStack(spacing: SolaroSpace.xs) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(SolaroColor.accent)
                    Text("runtime \(AROVersion.shortVersion)")
                        .font(SolaroFont.body)
                        .foregroundStyle(SolaroColor.textPrimary)
                }
                HStack(spacing: SolaroSpace.xs) {
                    Image(systemName: "circle")
                        .foregroundStyle(SolaroColor.textTertiary)
                    Text("no events yet — run something")
                        .font(SolaroFont.caption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
            }
            .padding(SolaroSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .solaroCard()
        }
        .padding(.top, SolaroSpace.s)
    }
}

// MARK: - Feature set card

private struct FeatureSetCard: View {
    let fs: FeatureSet

    @State private var expanded: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Role-tinted stripe on the left edge of every card.
            Rectangle()
                .fill(stripeColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: SolaroSpace.xs) {
                HStack(spacing: SolaroSpace.xs) {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(SolaroColor.textSecondary)
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fs.name)
                            .font(SolaroFont.bodyBold)
                            .foregroundStyle(SolaroColor.textPrimary)
                            .lineLimit(1)
                        Text(fs.businessActivity.isEmpty ? "—" : fs.businessActivity)
                            .font(SolaroFont.caption)
                            .foregroundStyle(SolaroColor.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(fs.statements.count)")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(SolaroColor.divider)
                        )
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(fs.statements.enumerated()), id: \.offset) { _, stmt in
                            StatementRow(statement: stmt)
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.top, 4)
                }
            }
            .padding(SolaroSpace.s)
        }
        .background(SolaroColor.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .stroke(SolaroColor.divider, lineWidth: 1)
        )
    }

    /// Dominant role tint across the feature set's statements. Uses a
    /// majority-wins rule with EXPORT > REQUEST > OWN > RESPONSE as
    /// the tiebreak ordering — matches the wireframe's logic where
    /// exporting verbs dominate the visual.
    private var stripeColor: Color {
        var verbs: [String] = []
        for stmt in fs.statements {
            if let aro = stmt as? AROStatement {
                verbs.append(aro.action.verb)
            }
        }
        let roles = verbs.map(SolaroColor.roleColor(forVerb:))
        let counts = Dictionary(grouping: roles, by: { $0 }).mapValues(\.count)
        let priority: [Color] = [
            SolaroColor.roleExport,
            SolaroColor.roleRequest,
            SolaroColor.roleOwn,
            SolaroColor.roleResponse,
        ]
        for color in priority {
            if (counts[color] ?? 0) > 0 { return color }
        }
        return SolaroColor.accent
    }
}

// MARK: - Statement row

private struct StatementRow: View {
    let statement: any Statement

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let aro = statement as? AROStatement {
                Circle()
                    .fill(SolaroColor.roleColor(forVerb: aro.action.verb))
                    .frame(width: 4, height: 4)
                Text(aro.action.verb)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.roleColor(forVerb: aro.action.verb))
                Text("<\(aro.result.base)>")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textPrimary)
                Text("…")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            } else if let pub = statement as? PublishStatement {
                Circle()
                    .fill(SolaroColor.roleExport)
                    .frame(width: 4, height: 4)
                Text("Publish")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.roleExport)
                Text("<\(pub.internalVariable)> as \(pub.externalName)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textPrimary)
            }
            Spacer(minLength: 0)
        }
    }
}
