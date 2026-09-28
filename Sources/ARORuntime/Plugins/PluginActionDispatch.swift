// ============================================================
// PluginActionDispatch.swift
// ARO Runtime — which name to ask a plugin for an action by
// GitLab #884
// ============================================================
//
// `aro_plugin_execute(action, input)` takes a name, and the SDKs disagree
// about which name that is. `aro-plugin-sdk-rust`'s macro writes the
// manifest from the declared `name:`/`verbs:` but registers only the Rust
// *function* name — snake_case of the action name — in its dispatch table.
// So a plugin advertising `ParseCSV` with verb `parsecsv` answers
// `{"error":"Unknown action: parsecsv"}` and expects `parse_csv`.
//
// `NativePluginHost` had worked around that for dlopen'd plugins since the
// SDK shipped, by retrying with snake_case candidates. `PluginLoader`'s C
// path — which is what a **statically linked** plugin goes through — did
// not, so the same plugin worked under `aro run` and failed under
// `aro build`:
//
//     Examples/CSVProcessor (compiled):  Cannot parsecsv the parsed from the csv-data.
//     Examples/SQLiteExample (compiled): Cannot call the create-result from the sqlite: execute.
//
// Both hosts share this now. Two copies of a workaround is how one of them
// stays behind, and the one that stayed behind was the one nobody exercised
// — both examples' `expected.txt` asserted a banner line and a note that the
// plugin might not load, so the test passed either way (GitLab #820).

import Foundation

public enum PluginActionDispatch {

    /// The SDK's sentinel for "I do not have that action".
    ///
    /// Matched as a substring because the SDKs wrap it differently —
    /// `{"error":"[InternalError] Unknown action: parsecsv"}` from Rust.
    public static func isUnknownAction(_ responseJSON: String) -> Bool {
        responseJSON.contains("Unknown action:")
    }

    /// Names to try, in order, when asking a plugin to run `verb`.
    ///
    /// The verb as written comes first — that is what a correctly
    /// dispatching plugin wants, and most do. Then the snake_case form of
    /// every action name the manifest advertises for this verb, then the
    /// snake_case of the verb itself.
    ///
    /// - Parameter verbsByName: action name → its declared verbs, from
    ///   `aro_plugin_info`.
    public static func candidates(for verb: String, verbsByName: [String: [String]]) -> [String] {
        var out = [verb]
        let lowered = verb.lowercased()
        for (name, verbs) in verbsByName.sorted(by: { $0.key < $1.key }) {
            if name.lowercased() == lowered
                || verbs.contains(where: { $0.lowercased() == lowered }) {
                out.append(snakeCased(name))
            }
        }
        out.append(snakeCased(verb))

        // Order-preserving de-duplication: the first spelling that works
        // should be the one tried first, and a plugin that errors on an
        // unknown name should not be asked twice.
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// CamelCase → snake_case, matching the convention
    /// `aro-plugin-sdk-rust` uses to derive a function name:
    ///
    ///   ParseCSV   → parse_csv
    ///   CSVToJSON  → csv_to_json
    ///   FormatCSV  → format_csv
    ///
    /// Insert `_` between (lowercase | digit) and uppercase — the start of
    /// a new word — and between two uppercases when the second is followed
    /// by a lowercase, which ends an acronym run. Consecutive uppercases
    /// otherwise stay together, so `CSV` does not become `c_s_v`.
    public static func snakeCased(_ s: String) -> String {
        let chars = Array(s)
        guard !chars.isEmpty else { return s }
        var out = ""
        for i in 0..<chars.count {
            let ch = chars[i]
            if i > 0, ch.isUppercase {
                let prev = chars[i - 1]
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextLower) {
                    out.append("_")
                }
            }
            out.append(Character(ch.lowercased()))
        }
        return out
    }
}
