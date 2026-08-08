// ============================================================
// ResultTypeCoercion.swift
// ARO Runtime - `as <Type>` result annotations (GitLab #475)
// ============================================================

import Foundation
import AROParser

/// Honours the `as <Type>` result annotation documented in ARO-0003.
///
/// The annotation is presented as the canonical way to ask for decimal
/// precision — "`<total> as Float` when you need decimals" (ARO-0003 §Type
/// Inference) — but `Compute` ignored it entirely, so
/// `Compute the <d> as Float from <x> / 2.` still truncated to 3. `Reduce`
/// honoured it, so behaviour varied per action, which was the real defect.
enum ResultTypeCoercion {

    /// Type names that request floating-point evaluation.
    private static let floatTypes: Set<String> = ["float", "double", "decimal"]

    /// Type names that request an integer result.
    private static let integerTypes: Set<String> = ["integer", "int"]

    /// Whether `asType` asks for a floating-point result.
    static func requestsFloat(_ asType: String?) -> Bool {
        guard let asType else { return false }
        return floatTypes.contains(asType.lowercased())
    }

    /// Whether `asType` asks for an integer result.
    static func requestsInteger(_ asType: String?) -> Bool {
        guard let asType else { return false }
        return integerTypes.contains(asType.lowercased())
    }

    /// Picks the evaluator for a statement carrying `asType`.
    ///
    /// Returns `fallback` unchanged when the annotation is absent or is not a
    /// numeric type, so nothing else changes behaviour.
    static func evaluator(
        for asType: String?,
        default fallback: ExpressionEvaluator
    ) -> ExpressionEvaluator {
        requestsFloat(asType) ? ExpressionEvaluator(numericMode: .float) : fallback
    }

    /// Coerces an already-computed value to the annotated type.
    ///
    /// Used for the paths that do not go through expression evaluation — e.g.
    /// `Compute the <n: length> as Float from <s>.`, where the operation produces
    /// an Int that the annotation asks to widen. Returns `value` untouched when
    /// there is nothing to do, so a non-numeric annotation (a schema name, say)
    /// is left alone rather than mangled.
    static func coerce(_ value: any Sendable, to asType: String?) -> any Sendable {
        guard let asType else { return value }

        if requestsFloat(asType) {
            if let i = value as? Int { return Double(i) }
            if let d = value as? Double { return d }
            // Widening a numeric string is a convenience the annotation implies.
            if let s = value as? String, let d = Double(s) { return d }
            return value
        }

        if requestsInteger(asType) {
            if let d = value as? Double {
                // Only narrow when it is lossless and representable; silently
                // truncating 3.7 to 3 under an annotation would be its own bug.
                if let i = Int(exactly: d.rounded()), d == d.rounded() { return i }
                return value
            }
            if let s = value as? String, let i = Int(s) { return i }
            return value
        }

        return value
    }
}
