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
                variablesSection
                lspDiagnosticsSection
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
                    lspStatus
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
    private var lspStatus: some View {
        let entries = lspDiagnosticsForCurrentFile
        if !controller.lsp.isReady {
            HStack(spacing: SolaroSpace.xs) {
                ProgressView().controlSize(.mini)
                Text("LSP starting…")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
        } else if !entries.isEmpty {
            let errs = entries.filter { $0.severity == .error }.count
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: errs > 0
                      ? "exclamationmark.octagon.fill"
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(errs > 0
                                     ? SolaroColor.stateError
                                     : SolaroColor.stateWarn)
                Text("LSP · \(entries.count) diagnostic\(entries.count == 1 ? "" : "s")")
                    .font(SolaroFont.caption)
                    .foregroundStyle(errs > 0
                                     ? SolaroColor.stateError
                                     : SolaroColor.stateWarn)
            }
        } else {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(SolaroColor.stateOK)
                Text("LSP · clean")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var variablesSection: some View {
        // Render the section whenever the debugger is paused, even
        // when the symbol bag happens to be empty — empties used
        // to make the whole section vanish, leaving the user
        // wondering where it went.
        if controller.pausedLine != nil {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                HStack {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(SolaroColor.stateWarn)
                    Text("DEBUGGER · VARIABLES")
                        .font(SolaroFont.sectionTitle)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .tracking(2)
                    Spacer()
                    if let line = controller.pausedLine {
                        Text("line \(line)")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.stateWarn)
                    }
                }
                variableList
            }
            .padding(.top, SolaroSpace.s)
        }
    }

    @ViewBuilder
    private var variableList: some View {
        let symbols = sortedPauseSymbols
        VStack(alignment: .leading, spacing: 1) {
            if symbols.isEmpty {
                Text("No variables captured at this pause.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Text("Step / continue to a statement that binds one.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            } else {
                ForEach(symbols, id: \.name) { sym in
                    VariableRow(symbol: sym)
                }
            }
        }
        .padding(.vertical, SolaroSpace.xs)
        .padding(.horizontal, SolaroSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solaroCard()
    }

    private var sortedPauseSymbols: [ConsoleProcess.SymbolValue] {
        controller.pauseSymbols.values.sorted { $0.name < $1.name }
    }

    @ViewBuilder
    private var lspDiagnosticsSection: some View {
        let entries = lspDiagnosticsForCurrentFile
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                Text("LSP DIAGNOSTICS")
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .tracking(2)
                ForEach(entries) { d in
                    LSPDiagnosticRow(diagnostic: d)
                }
            }
            .padding(.top, SolaroSpace.s)
        }
    }

    private var lspDiagnosticsForCurrentFile: [AROLSPClient.Diagnostic] {
        guard let url = controller.currentFile else { return [] }
        return controller.lsp.diagnostics[url] ?? []
    }

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

// MARK: - Variable row

private struct VariableRow: View {
    let symbol: ConsoleProcess.SymbolValue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(symbol.name)
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.accent)
            Text(":")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            Text(symbol.typeName)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textSecondary)
            Text("=")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            Text(symbol.value)
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
    }
}

// MARK: - LSP diagnostic row

private struct LSPDiagnosticRow: View {
    let diagnostic: AROLSPClient.Diagnostic

    var body: some View {
        HStack(alignment: .top, spacing: SolaroSpace.xs) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("line \(diagnostic.line):\(diagnostic.character)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Text(diagnostic.message)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(SolaroSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.s)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }

    private var icon: String {
        switch diagnostic.severity {
        case .error:   return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        case .hint:    return "lightbulb.fill"
        }
    }

    private var color: Color {
        switch diagnostic.severity {
        case .error:   return SolaroColor.stateError
        case .warning: return SolaroColor.stateWarn
        case .info:    return SolaroColor.accent
        case .hint:    return SolaroColor.textSecondary
        }
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
