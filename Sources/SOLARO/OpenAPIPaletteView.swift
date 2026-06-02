// ============================================================
// OpenAPIPaletteView.swift
// SOLARO — OpenAPI endpoint palette overlay (Phase 11)
// ============================================================
//
// Wireframe target: note 8467 figure 10 (OpenAPI palette).
//
// A modal sheet opened with ⌘K from the status bar. Lists every
// HTTP endpoint discovered in `openapi.yaml` and marks whether a
// matching feature set already exists in the project. Selecting
// an unmatched endpoint scaffolds a stub feature set (Phase 11+
// follow-up — for now just navigates to the file containing the
// matching feature set, or shows a hint).

import SwiftUI

struct OpenAPIPaletteView: View {
    let endpoints: [OpenAPIEndpoint]
    let onClose: () -> Void
    let onSelect: (OpenAPIEndpoint) -> Void

    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            if filtered.isEmpty {
                emptyState
            } else {
                List(filtered) { endpoint in
                    Button {
                        onSelect(endpoint)
                    } label: {
                        EndpointRow(endpoint: endpoint)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 560, height: 480)
        .background(SolaroColor.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            HStack {
                Text("OpenAPI palette")
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            TextField("Filter endpoints", text: $query)
                .textFieldStyle(.roundedBorder)
            Text("\(filtered.count) endpoint\(filtered.count == 1 ? "" : "s") · click to navigate")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(SolaroSpace.m)
    }

    private var emptyState: some View {
        VStack(spacing: SolaroSpace.s) {
            Spacer()
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(SolaroColor.textTertiary)
            Text(query.isEmpty
                 ? "No endpoints in openapi.yaml — or there's no openapi.yaml."
                 : "No endpoints match “\(query)”.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var filtered: [OpenAPIEndpoint] {
        guard !query.isEmpty else { return endpoints }
        let q = query.lowercased()
        return endpoints.filter {
            $0.id.lowercased().contains(q)
                || ($0.operationId?.lowercased().contains(q) ?? false)
                || ($0.summary?.lowercased().contains(q) ?? false)
        }
    }
}

private struct EndpointRow: View {
    let endpoint: OpenAPIEndpoint

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            Text(endpoint.method)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(methodColor)
                .frame(width: 56, alignment: .leading)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(methodColor.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(endpoint.path)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let op = endpoint.operationId {
                        Text(op)
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textSecondary)
                    }
                    if let summary = endpoint.summary {
                        Text("·  \(summary)")
                            .font(SolaroFont.caption)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            if endpoint.used {
                Label("wired", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(SolaroColor.stateOK)
            } else {
                Label("missing", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(SolaroColor.stateWarn)
            }
        }
        .padding(.vertical, SolaroSpace.xs)
        .padding(.horizontal, SolaroSpace.s)
    }

    /// HTTP-method tinting: GET blue, POST green, PUT/PATCH amber,
    /// DELETE red, everything else neutral. Matches the wireframe
    /// note 8467 figure 10 color callout.
    private var methodColor: Color {
        switch endpoint.method {
        case "GET":    return SolaroColor.roleRequest
        case "POST":   return SolaroColor.roleResponse
        case "PUT", "PATCH": return SolaroColor.roleExport
        case "DELETE": return SolaroColor.stateError
        default: return SolaroColor.textSecondary
        }
    }
}
