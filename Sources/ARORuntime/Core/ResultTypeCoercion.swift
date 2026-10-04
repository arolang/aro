// ============================================================
// ResultTypeCoercion.swift
// ARO Runtime - `as <Type>` result annotations (GitLab #475, #906)
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
///
/// The name table itself lives in `AROParser.NumberFormatCatalog`, because
/// `aro check` and the LLVM code generator need the same answer and neither
/// loads this module (GitLab #906).
enum ResultTypeCoercion {

    /// Whether `asType` asks for a floating-point result.
    static func requestsFloat(_ asType: String?) -> Bool {
        NumberFormatCatalog.format(for: asType) == .float
    }

    /// Whether `asType` asks for an integer result.
    static func requestsInteger(_ asType: String?) -> Bool {
        NumberFormatCatalog.format(for: asType) == .integer
    }

    /// Whether `asType` asks for exact base-10 arithmetic — `as Currency` or
    /// `as Decimal` (GitLab #906).
    static func requestsExact(_ asType: String?) -> Bool {
        NumberFormatCatalog.format(for: asType) == .exact
    }

    /// Picks the evaluator for a statement carrying `asType`.
    ///
    /// Returns `fallback` unchanged when the annotation is absent or is not a
    /// numeric type, so nothing else changes behaviour.
    static func evaluator(
        for asType: String?,
        default fallback: ExpressionEvaluator
    ) -> ExpressionEvaluator {
        switch NumberFormatCatalog.format(for: asType) {
        case .float: return ExpressionEvaluator(numericMode: .float)
        case .exact: return ExpressionEvaluator(numericMode: .exact)
        case .integer, .natural: return fallback
        }
    }

    /// Coerces an already-computed value to the annotated type.
    ///
    /// Used for the paths that do not go through expression evaluation — e.g.
    /// `Compute the <n: length> as Float from <s>.`, where the operation produces
    /// an Int that the annotation asks to widen. Returns `value` untouched when
    /// there is nothing to do, so a non-numeric annotation (a schema name, say)
    /// is left alone rather than mangled.
    static func coerce(_ value: any Sendable, to asType: String?) -> any Sendable {
        coerce(value, as: NumberFormatCatalog.format(for: asType))
    }

    /// The same coercion from an already-classified format. The compiled path
    /// has only the format, having read it off the `_as_type_` modifier.
    static func coerce(_ value: any Sendable, as format: AroNumberFormat) -> any Sendable {
        switch format {
        case .natural:
            return value

        case .float:
            if let c = value as? AROCurrency { return c.doubleValue }
            if let i = value as? Int { return Double(i) }
            if let d = value as? Double { return d }
            // Widening a numeric string is a convenience the annotation implies.
            if let s = value as? String, let d = Double(s) { return d }
            return value

        case .integer:
            if let c = value as? AROCurrency {
                // Same rule as the Double case below: narrow only when it is
                // lossless, so `as Integer` never silently drops cents.
                if let whole = try? c.rescaled(to: 0), whole == c { return whole.units }
                return value
            }
            if let d = value as? Double {
                // Only narrow when it is lossless and representable; silently
                // truncating 3.7 to 3 under an annotation would be its own bug.
                if let i = Int(exactly: d.rounded()), d == d.rounded() { return i }
                return value
            }
            if let s = value as? String, let i = Int(s) { return i }
            return value

        case .exact:
            // GitLab #906. A `Double` is converted by its decimal *spelling*,
            // so a price that entered the program as `2.40` from a CSV becomes
            // exactly `2.4` and is exact from here on. A value that is not a
            // number at all is left alone — the action reports that, since
            // only it knows which statement asked.
            if value is AROCurrency { return value }
            return AROCurrency.from(value) ?? value
        }
    }
}

extension AroNumberFormat {
    /// The interpreter's evaluator mode for this annotation.
    ///
    /// One mapping, used by `ResultTypeCoercion.evaluator` for `aro run` and
    /// by `evaluateBinaryOp` for a compiled binary, so the two modes cannot
    /// disagree about what `as Currency` means (GitLab #906).
    var interpreterMode: ExpressionEvaluator.NumericMode {
        switch self {
        case .float: return .float
        case .exact: return .exact
        case .integer, .natural: return .natural
        }
    }
}
