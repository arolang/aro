// ============================================================
// OpenAPITryItOut.swift
// SOLARO — fire a request against a running server (#249)
// ============================================================
//
// Inspector sub-section shown for the selected OpenAPI route.
// Lets the user type a base URL + path parameters + query +
// optional JSON body, hit Send, and see the response panel
// (status code tinted by class, headers, pretty-printed body).
//
// Storage: per-project history saved to .solaro/try-it-out.json
// so the user can re-fire the last request without retyping it.

import SwiftUI
import Foundation

@MainActor
@Observable
final class TryItOutModel {
    var baseURL: String = "http://localhost:8080"
    var pathParamValues: [String: String] = [:]
    var queryParamValues: [String: String] = [:]
    var headerValues: [String: String] = [:]
    var requestBody: String = ""
    private(set) var lastResponse: Response?
    private(set) var isSending: Bool = false
    private(set) var lastError: String?

    struct Response: Equatable {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    func send(method: String, path: String) {
        let url = composeURL(method: method, path: path)
        guard let url else {
            lastError = "Bad URL — fix base URL or path parameters."
            return
        }
        isSending = true
        lastError = nil
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in headerValues where !v.isEmpty {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if !requestBody.isEmpty,
           ["POST", "PUT", "PATCH", "DELETE"].contains(method.uppercased())
        {
            request.httpBody = requestBody.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        Task.detached(priority: .userInitiated) {
            await self.perform(request: request)
        }
    }

    nonisolated private func perform(request: URLRequest) async {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            var headers: [String: String] = [:]
            for (k, v) in (http?.allHeaderFields ?? [:]) {
                if let key = k as? String, let value = v as? String {
                    headers[key] = value
                }
            }
            let body = prettyPrint(data: data, contentType: headers["Content-Type"])
            await MainActor.run {
                self.lastResponse = Response(status: status, headers: headers, body: body)
                self.isSending = false
            }
        } catch {
            await MainActor.run {
                self.lastError = error.localizedDescription
                self.isSending = false
            }
        }
    }

    private nonisolated func prettyPrint(data: Data, contentType: String?) -> String {
        if let contentType, contentType.contains("json"),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
             withJSONObject: object,
             options: [.prettyPrinted, .sortedKeys]
           ),
           let text = String(data: pretty, encoding: .utf8)
        {
            return text
        }
        return String(data: data, encoding: .utf8) ?? "(binary, \(data.count) bytes)"
    }

    /// Build the request URL: base + path with `{name}` substituted
    /// from pathParamValues + query string from queryParamValues.
    private func composeURL(method: String, path: String) -> URL? {
        var resolvedPath = path
        for (k, v) in pathParamValues {
            resolvedPath = resolvedPath.replacingOccurrences(
                of: "{\(k)}",
                with: v.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? v
            )
        }
        let separator = baseURL.hasSuffix("/") ? "" : ""
        var fullURL = baseURL + separator + resolvedPath
        let queryItems = queryParamValues
            .filter { !$1.isEmpty }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        if !queryItems.isEmpty {
            var components = URLComponents(string: fullURL)
            components?.queryItems = queryItems
            fullURL = components?.url?.absoluteString ?? fullURL
        }
        return URL(string: fullURL)
    }
}

struct OpenAPITryItOutView: View {
    @Bindable var model: TryItOutModel
    let method: String
    let path: String
    let parameters: [[String: Any]]

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            Text("Try it")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
                .padding(.top, SolaroSpace.xs)
            FormRowInline(label: "Base URL") {
                TextField("http://localhost:8080", text: $model.baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            if !pathParameters.isEmpty {
                ForEach(pathParameters, id: \.self) { name in
                    FormRowInline(label: name) {
                        TextField("path", text: pathBinding(name))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            if !queryParameters.isEmpty {
                Text("Query")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                ForEach(queryParameters, id: \.self) { name in
                    FormRowInline(label: name) {
                        TextField("query", text: queryBinding(name))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            if ["POST", "PUT", "PATCH"].contains(method.uppercased()) {
                Text("Body (JSON)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                TextEditor(text: $model.requestBody)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(SolaroColor.backdrop)
                    .frame(minHeight: 80, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
                    .overlay(
                        RoundedRectangle(cornerRadius: SolaroRadius.s)
                            .stroke(SolaroColor.divider, lineWidth: 1)
                    )
            }
            HStack {
                Spacer()
                if model.isSending {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.send(method: method, path: path)
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSending)
            }
            if let error = model.lastError {
                Text(error)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.stateError)
            }
            if let response = model.lastResponse {
                responseView(response)
            }
        }
    }

    private var pathParameters: [String] {
        parameters
            .filter { ($0["in"] as? String) == "path" }
            .compactMap { $0["name"] as? String }
    }

    private var queryParameters: [String] {
        parameters
            .filter { ($0["in"] as? String) == "query" }
            .compactMap { $0["name"] as? String }
    }

    private func pathBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { model.pathParamValues[name] ?? "" },
            set: { model.pathParamValues[name] = $0 }
        )
    }

    private func queryBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { model.queryParamValues[name] ?? "" },
            set: { model.queryParamValues[name] = $0 }
        )
    }

    @ViewBuilder
    private func responseView(_ response: TryItOutModel.Response) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SolaroSpace.xs) {
                Text("\(response.status)")
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(statusColor(response.status))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor(response.status).opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("\(response.body.utf8.count) bytes")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
            }
            ScrollView {
                Text(response.body)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 160)
            .padding(SolaroSpace.s)
            .background(SolaroColor.backdrop)
            .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
            .overlay(
                RoundedRectangle(cornerRadius: SolaroRadius.s)
                    .stroke(SolaroColor.divider, lineWidth: 1)
            )
        }
    }

    private func statusColor(_ status: Int) -> Color {
        switch status / 100 {
        case 2: return SolaroColor.stateOK
        case 3: return SolaroColor.accent
        case 4: return SolaroColor.stateWarn
        case 5: return SolaroColor.stateError
        default: return SolaroColor.textSecondary
        }
    }
}

private struct FormRowInline<Content: View>: View {
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
