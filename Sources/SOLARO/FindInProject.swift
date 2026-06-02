// ============================================================
// FindInProject.swift
// SOLARO — project-wide find & replace (#237)
// ============================================================
//
// Sheet shown via ⇧⌘F. Scans every .aro / .yaml / .store file in
// the loaded ProjectModel for matches of the user's query (with
// case-sensitivity, whole-word, and regex toggles), groups hits
// by file, and offers per-match Replace + Replace All.

import SwiftUI
import Foundation

struct FindMatch: Identifiable, Equatable {
    let id: String
    let file: URL
    let line: Int        // 1-indexed
    let column: Int      // 1-indexed
    let range: NSRange   // in the file's full text
    let preview: String  // the matching line with the match
}

struct FindResult: Identifiable {
    var id: String { file.path }
    let file: URL
    let matches: [FindMatch]
}

@MainActor
@Observable
final class FindInProjectModel {
    var query: String = ""
    var replacement: String = ""
    var caseSensitive: Bool = false
    var wholeWord: Bool = false
    var regex: Bool = false
    private(set) var results: [FindResult] = []
    private(set) var totalMatches: Int = 0
    private(set) var error: String?

    /// Re-run the search across the workspace. Called whenever
    /// the user types in the query field or flips a toggle.
    func search(in model: ProjectModel) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            totalMatches = 0
            error = nil
            return
        }
        var grouped: [FindResult] = []
        var matchCount = 0
        do {
            let regexObj = try compileRegex(query: trimmed)
            for url in candidateFiles(in: model) {
                guard let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                let matches = scan(text: text, in: url, regex: regexObj)
                if !matches.isEmpty {
                    grouped.append(FindResult(file: url, matches: matches))
                    matchCount += matches.count
                }
                if matchCount > 1000 { break }   // safety cap
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            grouped = []
            matchCount = 0
        }
        results = grouped
        totalMatches = matchCount
    }

    /// Replace one specific match.
    func replace(_ match: FindMatch, in model: ProjectModel) {
        applyReplacements(
            in: match.file,
            ranges: [match.range],
            replacement: replacement
        )
        search(in: model)
    }

    /// Replace every match across the whole result set. Iterates
    /// in reverse range order per file so earlier replacements
    /// don't invalidate later NSRange offsets.
    func replaceAll(in model: ProjectModel) {
        for result in results {
            let sortedRanges = result.matches
                .map(\.range)
                .sorted { $0.location > $1.location }
            applyReplacements(
                in: result.file,
                ranges: sortedRanges,
                replacement: replacement
            )
        }
        search(in: model)
    }

    // MARK: - Helpers

    private func candidateFiles(in model: ProjectModel) -> [URL] {
        var files: [URL] = []
        files.append(contentsOf: model.sourceFiles)
        files.append(contentsOf: model.storeFiles)
        if let spec = model.openAPISpec { files.append(spec) }
        return files
    }

    private func compileRegex(query: String) throws -> NSRegularExpression {
        var pattern = query
        if !regex {
            pattern = NSRegularExpression.escapedPattern(for: pattern)
        }
        if wholeWord {
            pattern = "\\b\(pattern)\\b"
        }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: options)
    }

    private func scan(text: String, in url: URL,
                      regex: NSRegularExpression) -> [FindMatch] {
        let ns = text as NSString
        let matches = regex.matches(in: text,
                                    range: NSRange(location: 0, length: ns.length))
        return matches.enumerated().map { (idx, result) in
            let (line, column, preview) = locate(range: result.range, in: ns)
            return FindMatch(
                id: "\(url.path)#\(idx)#\(result.range.location)",
                file: url,
                line: line,
                column: column,
                range: result.range,
                preview: preview
            )
        }
    }

    /// Map an NSRange in `text` to a 1-indexed (line, column) plus
    /// the surrounding line as a preview.
    private func locate(range: NSRange,
                        in ns: NSString) -> (Int, Int, String) {
        var line = 1
        var lineStart = 0
        for i in 0..<min(range.location, ns.length) {
            if ns.character(at: i) == 0x0A {
                line += 1
                lineStart = i + 1
            }
        }
        var lineEnd = range.location
        while lineEnd < ns.length, ns.character(at: lineEnd) != 0x0A {
            lineEnd += 1
        }
        let preview = ns.substring(with: NSRange(
            location: lineStart, length: max(lineEnd - lineStart, 0)
        ))
        return (line, range.location - lineStart + 1, preview)
    }

    private func applyReplacements(in url: URL,
                                   ranges: [NSRange],
                                   replacement: String) {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let ns = NSMutableString(string: text)
        for range in ranges {
            guard range.location + range.length <= ns.length else { continue }
            ns.replaceCharacters(in: range, with: replacement)
        }
        text = ns as String
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct FindInProjectSheet: View {
    @Bindable var model: FindInProjectModel
    let project: Project
    let projectModel: ProjectModel?
    let onClose: () -> Void
    let onJump: (URL, Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            queryBar
            Divider().background(SolaroColor.divider)
            results
        }
        .frame(width: 720, height: 540)
        .background(SolaroColor.surface)
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(SolaroColor.accent)
            Text("FIND IN PROJECT")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
            Spacer()
            Text("\(model.totalMatches) match\(model.totalMatches == 1 ? "" : "es")")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            Button("Close") { onClose() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
    }

    private var queryBar: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            HStack(spacing: SolaroSpace.s) {
                TextField("Find", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { triggerSearch() }
                Toggle("Aa", isOn: $model.caseSensitive)
                    .toggleStyle(.button).controlSize(.small)
                Toggle("ab", isOn: $model.wholeWord)
                    .toggleStyle(.button).controlSize(.small)
                    .help("Whole word")
                Toggle(".*", isOn: $model.regex)
                    .toggleStyle(.button).controlSize(.small)
                    .help("Regular expression")
            }
            HStack(spacing: SolaroSpace.s) {
                TextField("Replace with", text: $model.replacement)
                    .textFieldStyle(.roundedBorder)
                Button("Replace all") {
                    guard let projectModel else { return }
                    model.replaceAll(in: projectModel)
                }
                .disabled(model.results.isEmpty)
            }
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
        .onChange(of: model.query) { _, _ in triggerSearch() }
        .onChange(of: model.caseSensitive) { _, _ in triggerSearch() }
        .onChange(of: model.wholeWord) { _, _ in triggerSearch() }
        .onChange(of: model.regex) { _, _ in triggerSearch() }
    }

    @ViewBuilder
    private var results: some View {
        if let error = model.error {
            VStack(alignment: .leading, spacing: SolaroSpace.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SolaroColor.stateError)
                Text(error)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.stateError)
            }
            .padding(SolaroSpace.m)
        } else if model.results.isEmpty {
            VStack {
                Spacer()
                Text(model.query.isEmpty
                     ? "Type something to search."
                     : "No matches.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SolaroSpace.s) {
                    ForEach(model.results) { result in
                        ResultGroup(
                            result: result,
                            projectRoot: project.rootPath,
                            onJump: onJump,
                            onReplace: { match in
                                guard let projectModel else { return }
                                model.replace(match, in: projectModel)
                            }
                        )
                    }
                }
                .padding(SolaroSpace.m)
            }
        }
    }

    private func triggerSearch() {
        guard let projectModel else { return }
        model.search(in: projectModel)
    }
}

private struct ResultGroup: View {
    let result: FindResult
    let projectRoot: URL
    let onJump: (URL, Int) -> Void
    let onReplace: (FindMatch) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(SolaroColor.accent)
                Text(relativePath)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Spacer()
                Text("\(result.matches.count)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            ForEach(result.matches) { match in
                MatchRow(
                    match: match,
                    onJump: { onJump(match.file, match.line) },
                    onReplace: { onReplace(match) }
                )
            }
        }
    }

    private var relativePath: String {
        let rootPath = projectRoot.standardizedFileURL.path
        let filePath = result.file.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return result.file.lastPathComponent
    }
}

private struct MatchRow: View {
    let match: FindMatch
    let onJump: () -> Void
    let onReplace: () -> Void

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            Text("\(match.line):\(match.column)")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
                .frame(width: 64, alignment: .trailing)
            Text(match.preview.trimmingCharacters(in: .whitespaces))
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture { onJump() }
            Button("Replace", action: onReplace)
                .controlSize(.small)
        }
        .padding(.vertical, 1)
    }
}
