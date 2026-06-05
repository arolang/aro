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
                SelectedStatementSection(controller: controller)
                variablesSection
                WatchesSection(controller: controller, store: controller.watches)
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
                    Button(role: .destructive) {
                        deleteSelectedNode(nodeID, in: document)
                    } label: {
                        Label("Delete", systemImage: "trash")
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
                    document: document,
                    controller: controller
                )
                openAPILintList(for: nodeID, document: document)
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

    /// Remove the selected node from the document; clear the
    /// selection so the form goes away.
    private func deleteSelectedNode(_ nodeID: String, in document: OpenAPIDocument) {
        if let parsed = parseRouteIDForInspector(nodeID) {
            document.removeRoute(path: parsed.path, method: parsed.method)
        } else if nodeID.hasPrefix("schema:") {
            let name = String(nodeID.dropFirst("schema:".count))
            document.removeSchema(name: name)
        }
        controller.openAPISelectedNodeID = nil
    }

    private struct ParsedRouteIDForInspector {
        let method: String
        let path: String
    }

    private func parseRouteIDForInspector(_ id: String) -> ParsedRouteIDForInspector? {
        guard id.hasPrefix("route:") else { return nil }
        let payload = id.dropFirst("route:".count)
        let split = payload.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard split.count == 2 else { return nil }
        return .init(method: String(split[0]), path: String(split[1]))
    }

    /// Lint the document and return warnings attached to `nodeID`.
    /// Returns an empty array when the workspace isn't on an
    /// OpenAPI file or the file can't be read.
    private func lintWarnings(
        for nodeID: String,
        document: OpenAPIDocument
    ) -> [OpenAPILintWarning] {
        guard
            let url = controller.currentFile,
            let yaml = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        let graph = OpenAPIGraphBuilder.build(yaml: yaml)
        return OpenAPILinter.lint(graph: graph, document: document)
            .filter { $0.nodeID == nodeID }
    }

    @ViewBuilder
    private func openAPILintList(
        for nodeID: String,
        document: OpenAPIDocument
    ) -> some View {
        let warnings = lintWarnings(for: nodeID, document: document)
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lint")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                ForEach(warnings) { warning in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: warning.severity == .error
                              ? "exclamationmark.octagon.fill"
                              : "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(warning.severity == .error
                                             ? SolaroColor.stateError
                                             : SolaroColor.stateWarn)
                        Text(warning.message)
                            .font(SolaroFont.caption)
                            .foregroundStyle(SolaroColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, SolaroSpace.xs)
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
        let entries = projectDiagnostics
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                HStack {
                    Text("PROBLEMS")
                        .font(SolaroFont.sectionTitle)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .tracking(2)
                    Text("\(entries.count)")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                ForEach(entries) { entry in
                    Button {
                        controller.openFile(entry.url)
                        controller.currentLine = entry.diagnostic.line
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(relativePath(for: entry.url))
                                .font(SolaroFont.monoCaption)
                                .foregroundStyle(SolaroColor.textTertiary)
                            LSPDiagnosticRow(diagnostic: entry.diagnostic)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, SolaroSpace.s)
        }
    }

    /// Project-wide diagnostics flattened with their owning URL so
    /// the inspector can render a single "Problems" list.
    private var projectDiagnostics: [DiagnosticEntry] {
        var out: [DiagnosticEntry] = []
        for (url, diags) in controller.lsp.diagnostics {
            for d in diags { out.append(.init(url: url, diagnostic: d)) }
        }
        return out.sorted { lhs, rhs in
            if lhs.url.path != rhs.url.path { return lhs.url.path < rhs.url.path }
            return lhs.diagnostic.line < rhs.diagnostic.line
        }
    }

    private struct DiagnosticEntry: Identifiable {
        let url: URL
        let diagnostic: AROLSPClient.Diagnostic
        var id: String { "\(url.path):\(diagnostic.id)" }
    }

    private func relativePath(for url: URL) -> String {
        guard let model = controller.model else { return url.lastPathComponent }
        let root = model.root.rootPath.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    /// Diagnostics for the currently-edited file — used by the
    /// lspStatus chip in the feature-set section.
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
                    FeatureSetCard(fs: fs, controller: controller)
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
    @Bindable var controller: WorkspaceController

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
            parameterEditor(operation: operation, path: path, method: method)
            responseHints(operation: operation)
            OpenAPITryItOutView(
                model: controller.tryItOutModel,
                project: controller.model?.root,
                method: method,
                path: path,
                parameters: (operation["parameters"] as? [[String: Any]]) ?? []
            )
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
    private func parameterEditor(
        operation: [String: Any], path: String, method: String
    ) -> some View {
        let params = (operation["parameters"] as? [[String: Any]]) ?? []
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Parameters")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
                Button {
                    document.mutateRoute(path: path, method: method) { op in
                        var current = (op["parameters"] as? [[String: Any]]) ?? []
                        current.append([
                            "name": "newParam",
                            "in": "query",
                            "required": false,
                            "schema": ["type": "string"] as [String: Any],
                        ])
                        op["parameters"] = current
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
            ForEach(Array(params.enumerated()), id: \.offset) { idx, param in
                RouteParameterRow(
                    parameter: param,
                    onChange: { mutate in
                        document.mutateRoute(path: path, method: method) { op in
                            var current = (op["parameters"] as? [[String: Any]]) ?? []
                            guard idx < current.count else { return }
                            mutate(&current[idx])
                            op["parameters"] = current
                        }
                    },
                    onRemove: {
                        document.mutateRoute(path: path, method: method) { op in
                            var current = (op["parameters"] as? [[String: Any]]) ?? []
                            guard idx < current.count else { return }
                            current.remove(at: idx)
                            if current.isEmpty {
                                op.removeValue(forKey: "parameters")
                            } else {
                                op["parameters"] = current
                            }
                        }
                    }
                )
            }
        }
        .padding(.top, SolaroSpace.xs)
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
            SchemaNameField(currentName: name) { newName in
                document.renameSchema(from: name, to: newName)
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
        let required = Set((schema["required"] as? [Any])?
            .compactMap { $0 as? String } ?? [])
        VStack(alignment: .leading, spacing: 6) {
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
                        isRequired: required.contains(key),
                        availableSchemas: document.schemaNames,
                        onRename: { newName in
                            renameProperty(in: name, from: key, to: newName)
                        },
                        onChangeType: { choice in
                            document.setPropertyType(in: name,
                                                     propertyName: key,
                                                     kind: choice)
                        },
                        onToggleRequired: { req in
                            document.setPropertyRequired(in: name,
                                                         propertyName: key,
                                                         required: req)
                        },
                        onChangeDescription: { newDesc in
                            document.setPropertyDescription(in: name,
                                                            propertyName: key,
                                                            description: newDesc)
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

/// One parameter row in the route form. Edits route through
/// to OpenAPIDocument.mutateRoute via the `onChange` closure.
private struct RouteParameterRow: View {
    let parameter: [String: Any]
    let onChange: ((inout [String: Any]) -> Void) -> Void
    let onRemove: () -> Void

    @State private var nameDraft: String = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("name", text: Binding(
                get: { nameDraft.isEmpty ? (parameter["name"] as? String ?? "") : nameDraft },
                set: { nameDraft = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                let value = nameDraft
                onChange { p in p["name"] = value }
                nameDraft = ""
            }
            Picker("", selection: Binding(
                get: { parameter["in"] as? String ?? "query" },
                set: { newIn in onChange { p in p["in"] = newIn } }
            )) {
                Text("query").tag("query")
                Text("path").tag("path")
                Text("header").tag("header")
                Text("cookie").tag("cookie")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 90)
            Picker("", selection: Binding(
                get: {
                    ((parameter["schema"] as? [String: Any])?["type"] as? String) ?? "string"
                },
                set: { newType in
                    onChange { p in
                        var schema = (p["schema"] as? [String: Any]) ?? [:]
                        schema["type"] = newType
                        p["schema"] = schema
                    }
                }
            )) {
                Text("string").tag("string")
                Text("integer").tag("integer")
                Text("number").tag("number")
                Text("boolean").tag("boolean")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 90)
            Toggle("", isOn: Binding(
                get: { (parameter["required"] as? Bool) ?? false },
                set: { req in onChange { p in p["required"] = req } }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help("Required parameter")
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Editable form for the schema's name itself. Renaming
/// propagates through every `$ref` in the document via
/// OpenAPIDocument.renameSchema.
private struct SchemaNameField: View {
    let currentName: String
    let onCommit: (String) -> Void
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        FormRow(label: "Name") {
            TextField("schema name", text: Binding(
                get: { draft.isEmpty ? currentName : draft },
                set: { draft = $0 }
            ))
            .focused($focused)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                onCommit(draft)
                draft = ""
                focused = false
            }
            .onChange(of: focused) { _, isFocused in
                // Commit on focus-out too, so a click outside the
                // field doesn't silently drop the rename.
                if !isFocused, !draft.isEmpty, draft != currentName {
                    onCommit(draft)
                    draft = ""
                }
            }
        }
    }
}

private struct SchemaPropertyRow: View {
    let propertyName: String
    let property: [String: Any]
    let isRequired: Bool
    let availableSchemas: [String]
    let onRename: (String) -> Void
    let onChangeType: (OpenAPIDocument.PropertyTypeChoice) -> Void
    let onToggleRequired: (Bool) -> Void
    let onChangeDescription: (String) -> Void
    let onRemove: () -> Void

    @State private var draftName: String = ""
    @State private var descriptionDraft: String = ""
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                typePicker
                Toggle("", isOn: Binding(
                    get: { isRequired },
                    set: { onToggleRequired($0) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Required field")
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                .buttonStyle(.borderless)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                .buttonStyle(.borderless)
            }
            if expanded {
                TextField(
                    "description",
                    text: Binding(
                        get: {
                            descriptionDraft.isEmpty
                                ? (property["description"] as? String ?? "")
                                : descriptionDraft
                        },
                        set: { descriptionDraft = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    onChangeDescription(descriptionDraft)
                    descriptionDraft = ""
                }
            }
        }
    }

    /// Picker exposing every primitive type plus every existing
    /// component schema (set as `$ref`) and array-of-each.
    private var typePicker: some View {
        Picker("", selection: Binding(
            get: { currentChoice },
            set: { onChangeType($0) }
        )) {
            Section("Primitive") {
                Text("string").tag(OpenAPIDocument.PropertyTypeChoice.primitive("string"))
                Text("integer").tag(OpenAPIDocument.PropertyTypeChoice.primitive("integer"))
                Text("number").tag(OpenAPIDocument.PropertyTypeChoice.primitive("number"))
                Text("boolean").tag(OpenAPIDocument.PropertyTypeChoice.primitive("boolean"))
                Text("object").tag(OpenAPIDocument.PropertyTypeChoice.primitive("object"))
            }
            if !availableSchemas.isEmpty {
                Section("Schema") {
                    ForEach(availableSchemas, id: \.self) { s in
                        Text(s)
                            .tag(OpenAPIDocument.PropertyTypeChoice.schemaRef(s))
                    }
                }
                Section("Array of") {
                    Text("[string]")
                        .tag(OpenAPIDocument.PropertyTypeChoice.array(.primitive("string")))
                    Text("[integer]")
                        .tag(OpenAPIDocument.PropertyTypeChoice.array(.primitive("integer")))
                    ForEach(availableSchemas, id: \.self) { s in
                        Text("[\(s)]")
                            .tag(OpenAPIDocument.PropertyTypeChoice.array(.schemaRef(s)))
                    }
                }
            } else {
                Section("Array of") {
                    Text("[string]")
                        .tag(OpenAPIDocument.PropertyTypeChoice.array(.primitive("string")))
                    Text("[integer]")
                        .tag(OpenAPIDocument.PropertyTypeChoice.array(.primitive("integer")))
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 160)
    }

    /// Map the underlying YAML dict to the choice enum the picker
    /// binds against, so the current value pre-selects correctly.
    private var currentChoice: OpenAPIDocument.PropertyTypeChoice {
        if let refStr = property["$ref"] as? String {
            let prefix = "#/components/schemas/"
            if refStr.hasPrefix(prefix) {
                return .schemaRef(String(refStr.dropFirst(prefix.count)))
            }
        }
        if let typeStr = property["type"] as? String, typeStr == "array",
           let items = property["items"] as? [String: Any]
        {
            if let refStr = items["$ref"] as? String {
                let prefix = "#/components/schemas/"
                if refStr.hasPrefix(prefix) {
                    return .array(.schemaRef(String(refStr.dropFirst(prefix.count))))
                }
            }
            if let innerType = items["type"] as? String {
                return .array(.primitive(innerType))
            }
        }
        return .primitive(property["type"] as? String ?? "string")
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
    @Bindable var controller: WorkspaceController

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
                    testIcon
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

    /// Small "T" badge that surfaces the test status of this
    /// feature set: green when the last `aro test` recorded a
    /// pass, red on fail / error. While a test run is in
    /// progress (the FS recently fired a statement) the icon
    /// blinks to signal "the runtime is touching this right now".
    @ViewBuilder
    private var testIcon: some View {
        let result = controller.testResults[fs.name]
        let isTestFS = fs.businessActivity.hasSuffix("Test")
            || fs.businessActivity.hasSuffix("Tests")
        // Only show the icon for actual test feature sets so the
        // production rows stay visually quiet.
        if isTestFS {
            let _: UInt64 = controller.executionTick
            let recentExec = controller.lastExecutedAtPerFeatureSet[fs.name]
            TimelineView(.animation(minimumInterval: 1.0 / 12.0,
                                    paused: !isCurrentlyRunning(recentExec))) { ctx in
                let pulsing = isCurrentlyRunning(recentExec)
                let alpha = pulsing ? blinkAlpha(at: ctx.date) : 1.0
                Text("T")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(testIconColor(for: result, pulsing: pulsing))
                    .opacity(alpha)
                    .frame(width: 14, height: 14)
                    .background(
                        Circle()
                            .fill(testIconColor(for: result, pulsing: pulsing)
                                  .opacity(0.18))
                    )
                    .help(testIconTooltip(for: result, pulsing: pulsing))
            }
        }
    }

    private func isCurrentlyRunning(_ last: Date?) -> Bool {
        guard let last else { return false }
        return Date().timeIntervalSince(last) < 0.6
    }

    private func blinkAlpha(at now: Date) -> Double {
        // 1.2 Hz square-ish blink so the user catches it even out
        // of the corner of their eye.
        let t = now.timeIntervalSince1970
        return (sin(t * .pi * 2.4) > 0) ? 1.0 : 0.35
    }

    private func testIconColor(
        for result: TestNodeResult?,
        pulsing: Bool
    ) -> Color {
        switch result {
        case .passed: return SolaroColor.stateOK
        case .failed: return SolaroColor.stateError
        case nil:     return pulsing
            ? SolaroColor.accent
            : SolaroColor.textTertiary
        }
    }

    private func testIconTooltip(
        for result: TestNodeResult?,
        pulsing: Bool
    ) -> String {
        if pulsing { return "Test running…" }
        switch result {
        case .passed: return "Last run: passed"
        case .failed(let msg): return "Last run: \(msg)"
        case nil: return "Test (no run yet)"
        }
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
