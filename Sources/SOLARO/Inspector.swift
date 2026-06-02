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
                openAPIEditorSection
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
    private var openAPIEditorSection: some View {
        if let document = controller.openAPIDocument,
           let nodeID = controller.openAPISelectedNodeID
        {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                HStack {
                    Text("OPENAPI · \(nodeKindLabel(nodeID))")
                        .font(SolaroFont.sectionTitle)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .tracking(2)
                    Spacer()
                    if document.isDirty {
                        Text("modified")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.stateWarn)
                    }
                    Button {
                        document.save()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!document.isDirty)
                }
                OpenAPINodeForm(
                    nodeID: nodeID,
                    document: document
                )
                if let error = document.lastError {
                    Text(error)
                        .font(SolaroFont.caption)
                        .foregroundStyle(SolaroColor.stateError)
                }
            }
            .padding(.top, SolaroSpace.s)
        }
    }

    /// Pretty label for the section header ("route" / "schema").
    private func nodeKindLabel(_ nodeID: String) -> String {
        if nodeID.hasPrefix("route:") { return "ROUTE" }
        if nodeID.hasPrefix("inline:") { return "INLINE OBJECT" }
        return "SCHEMA"
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

// MARK: - OpenAPI editor form

/// Renders an editable form for the currently-selected OpenAPI
/// node. Today it edits the most common route fields (summary +
/// operationId); deeper editing (parameters, responses, schema
/// properties) lands in subsequent commits.
private struct OpenAPINodeForm: View {
    let nodeID: String
    @Bindable var document: OpenAPIDocument

    var body: some View {
        if let parsed = ParsedRouteID(from: nodeID) {
            routeForm(method: parsed.method, path: parsed.path)
        } else if nodeID.hasPrefix("schema:") {
            schemaForm(name: String(nodeID.dropFirst("schema:".count)))
        } else if nodeID.hasPrefix("inline:") {
            inlineNotice
        }
    }

    // MARK: Route form

    @ViewBuilder
    private func routeForm(method: String, path: String) -> some View {
        let operation = document.operation(path: path, method: method) ?? [:]
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            FormRow(label: "Method") {
                Text(method)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.accent)
            }
            FormRow(label: "Path") {
                Text(path)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .textSelection(.enabled)
            }
            FormRow(label: "operationId") {
                TextField("opId", text: textBinding(
                    initial: operation["operationId"] as? String ?? "",
                    apply: { newValue in
                        document.mutateRoute(path: path, method: method) { op in
                            if newValue.isEmpty {
                                op.removeValue(forKey: "operationId")
                            } else {
                                op["operationId"] = newValue
                            }
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
            FormRow(label: "summary") {
                TextField("summary", text: textBinding(
                    initial: operation["summary"] as? String ?? "",
                    apply: { newValue in
                        document.mutateRoute(path: path, method: method) { op in
                            if newValue.isEmpty {
                                op.removeValue(forKey: "summary")
                            } else {
                                op["summary"] = newValue
                            }
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
            FormRow(label: "description") {
                TextField("description", text: textBinding(
                    initial: operation["description"] as? String ?? "",
                    apply: { newValue in
                        document.mutateRoute(path: path, method: method) { op in
                            if newValue.isEmpty {
                                op.removeValue(forKey: "description")
                            } else {
                                op["description"] = newValue
                            }
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
            tagEditor(operation: operation, path: path, method: method)
            responseHints(operation: operation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func tagEditor(operation: [String: Any], path: String, method: String) -> some View {
        let tags = (operation["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        FormRow(label: "tags") {
            TextField(
                "comma-separated",
                text: textBinding(
                    initial: tags.joined(separator: ", "),
                    apply: { newValue in
                        let parsed = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        document.mutateRoute(path: path, method: method) { op in
                            if parsed.isEmpty {
                                op.removeValue(forKey: "tags")
                            } else {
                                op["tags"] = parsed
                            }
                        }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func responseHints(operation: [String: Any]) -> some View {
        if let responses = operation["responses"] as? [String: Any], !responses.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Responses")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                ForEach(responses.keys.sorted(), id: \.self) { status in
                    HStack(spacing: 4) {
                        Text(status)
                            .font(SolaroFont.mono)
                            .foregroundStyle(statusColor(status))
                        if let body = responses[status] as? [String: Any],
                           let desc = body["description"] as? String, !desc.isEmpty {
                            Text(desc)
                                .font(SolaroFont.caption)
                                .foregroundStyle(SolaroColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.top, SolaroSpace.xs)
        }
    }

    private func statusColor(_ status: String) -> Color {
        let n = Int(status) ?? 0
        switch n / 100 {
        case 2: return SolaroColor.stateOK
        case 3: return SolaroColor.accent
        case 4: return SolaroColor.stateWarn
        case 5: return SolaroColor.stateError
        default: return SolaroColor.textSecondary
        }
    }

    // MARK: Schema form

    @ViewBuilder
    private func schemaForm(name: String) -> some View {
        let schema = document.schema(name: name) ?? [:]
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            FormRow(label: "Name") {
                Text(name)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
            }
            FormRow(label: "description") {
                TextField("description", text: textBinding(
                    initial: schema["description"] as? String ?? "",
                    apply: { newValue in
                        document.mutateSchema(name: name) { s in
                            if newValue.isEmpty {
                                s.removeValue(forKey: "description")
                            } else {
                                s["description"] = newValue
                            }
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
            propertiesEditor(schema: schema, name: name)
        }
    }

    @ViewBuilder
    private func propertiesEditor(schema: [String: Any], name: String) -> some View {
        let props = (schema["properties"] as? [String: Any]) ?? [:]
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Properties")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
                Button {
                    var updated = props
                    var counter = updated.count + 1
                    var key = "newField"
                    while updated[key] != nil {
                        counter += 1
                        key = "newField\(counter)"
                    }
                    updated[key] = ["type": "string"]
                    document.mutateSchema(name: name) { s in
                        s["properties"] = updated
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
            ForEach(props.keys.sorted(), id: \.self) { key in
                if let p = props[key] as? [String: Any] {
                    SchemaPropertyRow(
                        propertyName: key,
                        property: p,
                        onRename: { newName in
                            renameProperty(in: name, from: key, to: newName)
                        },
                        onChangeType: { newType in
                            updatePropertyType(in: name, key: key, type: newType)
                        },
                        onRemove: {
                            removeProperty(in: name, key: key)
                        }
                    )
                }
            }
        }
        .padding(.top, SolaroSpace.xs)
    }

    private func renameProperty(in schemaName: String, from: String, to: String) {
        guard from != to, !to.isEmpty else { return }
        document.mutateSchema(name: schemaName) { schema in
            var props = (schema["properties"] as? [String: Any]) ?? [:]
            if let v = props.removeValue(forKey: from) {
                props[to] = v
                schema["properties"] = props
            }
        }
    }

    private func updatePropertyType(in schemaName: String, key: String, type: String) {
        document.mutateSchema(name: schemaName) { schema in
            var props = (schema["properties"] as? [String: Any]) ?? [:]
            var p = (props[key] as? [String: Any]) ?? [:]
            p["type"] = type
            // Drop $ref since type and $ref are mutually exclusive.
            p.removeValue(forKey: "$ref")
            props[key] = p
            schema["properties"] = props
        }
    }

    private func removeProperty(in schemaName: String, key: String) {
        document.mutateSchema(name: schemaName) { schema in
            var props = (schema["properties"] as? [String: Any]) ?? [:]
            props.removeValue(forKey: key)
            schema["properties"] = props
        }
    }

    private var inlineNotice: some View {
        Text("Inline component — edit via its parent route or schema.")
            .font(SolaroFont.caption)
            .foregroundStyle(SolaroColor.textTertiary)
    }

    // MARK: - Helpers

    /// Hand-rolled two-way binding wrapping a closure that mutates
    /// the document. We can't use `@Binding` directly because the
    /// underlying storage is `[String: Any]`.
    private func textBinding(
        initial: String,
        apply: @escaping (String) -> Void
    ) -> Binding<String> {
        Binding(
            get: { initial },
            set: { apply($0) }
        )
    }
}

private struct ParsedRouteID {
    let method: String
    let path: String
    init?(from id: String) {
        // "route:GET /users"
        guard id.hasPrefix("route:") else { return nil }
        let payload = id.dropFirst("route:".count)
        let split = payload.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard split.count == 2 else { return nil }
        self.method = String(split[0])
        self.path = String(split[1])
    }
}

private struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
                .frame(width: 90, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SchemaPropertyRow: View {
    let propertyName: String
    let property: [String: Any]
    let onRename: (String) -> Void
    let onChangeType: (String) -> Void
    let onRemove: () -> Void

    @State private var draftName: String = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("name", text: Binding(
                get: { draftName.isEmpty ? propertyName : draftName },
                set: { draftName = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                onRename(draftName)
                draftName = ""
            }
            Text(":")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            if let refStr = property["$ref"] as? String {
                Text(refStr.split(separator: "/").last.map(String.init) ?? "$ref")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.accent)
            } else {
                Picker("", selection: Binding(
                    get: { property["type"] as? String ?? "string" },
                    set: { onChangeType($0) }
                )) {
                    Text("string").tag("string")
                    Text("integer").tag("integer")
                    Text("number").tag("number")
                    Text("boolean").tag("boolean")
                    Text("array").tag("array")
                    Text("object").tag("object")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            }
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .buttonStyle(.borderless)
        }
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
                Image(systemName: "circle.fill")
                    .resizable()
                    .frame(width: 4, height: 4)
                    .foregroundStyle(SolaroColor.roleColor(forVerb: aro.action.verb))
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
                Image(systemName: "circle.fill")
                    .resizable()
                    .frame(width: 4, height: 4)
                    .foregroundStyle(SolaroColor.roleExport)
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
