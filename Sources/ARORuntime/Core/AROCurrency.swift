// ============================================================
// AROCurrency.swift
// ARO Runtime - the `Currency` number format (GitLab #906)
// ============================================================

import Foundation

/// An exact base-10 number: a scaled integer, not a `Double`.
///
/// `Compute the <line-total> as Currency from <qty> * <price>.` with `3` and
/// `2.40` is `7.2`, exactly, because the multiplication happens in base 10.
/// The same statement without the annotation is `7.199999999999999`, which is
/// binary floating point being accurate about itself and wrong about money.
///
/// ## Representation
///
/// `units` scaled by `scale` decimal places: `7.20` is `units: 720, scale: 2`.
/// Addition and subtraction align the two scales and add the integers;
/// multiplication multiplies the integers and adds the scales. Each of those is
/// exact or an error — never a quiet approximation. Division cannot be exact
/// (`10 / 3`), so it has a stated rule rather than a silent one: see `divided`.
///
/// ## Why not `Foundation.Decimal`
///
/// `Decimal` is a different implementation on Darwin and on
/// swift-corelibs-foundation, and its `description` normalises trailing zeros
/// differently between them. This type has to render identically in `aro run`,
/// in an `aro build` binary, and on both platforms, because those renderings
/// end up in committed `expected.txt` files and in data products. A scaled
/// `Int` is small enough to be obviously the same everywhere.
///
/// ## Limits
///
/// `scale` is at most ``maxScale`` and `units` is an `Int`. An operation that
/// cannot be represented within those is an error naming the operation, never
/// a wrapped or rounded result.
public struct AROCurrency: Sendable, Codable {

    /// The value, scaled by `scale` decimal places.
    public let units: Int

    /// Decimal places `units` is scaled by. `0...maxScale`.
    public let scale: Int

    /// The most decimal places an amount can carry.
    ///
    /// 18 is one short of `Int`'s decimal width, so a scale at the limit still
    /// leaves a whole digit for the integer part. Multiplication adds scales,
    /// which is the operation that reaches this first.
    public static let maxScale = 18

    /// Decimal places `divided` computes at.
    ///
    /// Four more than any circulating currency's minor unit, so an
    /// intermediate division never decides the cents. The rounding happens
    /// once, at the end, where the author asks for it.
    public static let divisionScale = 6

    public init(units: Int, scale: Int) {
        self.units = units
        self.scale = max(0, Swift.min(scale, Self.maxScale))
    }

    public init(_ value: Int) {
        self.units = value
        self.scale = 0
    }

    // MARK: - Conversion in

    /// The amount a `Double` *spells*, not the binary value it holds.
    ///
    /// `Double`'s own description is the shortest decimal that round-trips, so
    /// `2.40` read from a CSV arrives as the `Double` nearest `2.4` and comes
    /// back out as exactly `2.4`. Reading the spelling is what lets an amount
    /// that entered the program as a float become exact from there on.
    ///
    /// Returns `nil` for NaN and the infinities, which have no decimal form.
    public init?(_ value: Double) {
        guard value.isFinite else { return nil }
        guard let parsed = AROCurrency(decimalString: String(value)) else { return nil }
        self = parsed
    }

    /// Parses a decimal literal: `-12`, `7.20`, `1.5e-3`.
    public init?(decimalString raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        var mantissa = text
        var exponent = 0
        if let eIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(text[text.startIndex..<eIndex])
            let expText = String(text[text.index(after: eIndex)...])
            guard let e = Int(expText) else { return nil }
            exponent = e
        }

        var negative = false
        if mantissa.hasPrefix("-") { negative = true; mantissa.removeFirst() }
        else if mantissa.hasPrefix("+") { mantissa.removeFirst() }

        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let intPart = String(parts[0])
        let fracPart = parts.count == 2 ? String(parts[1]) : ""
        guard !(intPart.isEmpty && fracPart.isEmpty) else { return nil }
        guard intPart.allSatisfy(\.isNumber), fracPart.allSatisfy(\.isNumber) else { return nil }

        // digits / 10^(frac.count - exponent)
        var digits = intPart + fracPart
        var scale = fracPart.count - exponent
        if scale < 0 {
            // A positive exponent larger than the fraction: pad with zeros.
            guard -scale <= Self.maxScale * 2 else { return nil }
            digits += String(repeating: "0", count: -scale)
            scale = 0
        }
        if scale > Self.maxScale {
            // More decimals than the format carries. Round half-up to the
            // limit rather than truncating silently.
            let drop = scale - Self.maxScale
            guard digits.count > drop else { return nil }
            let keep = String(digits.dropLast(drop))
            let firstDropped = digits[digits.index(digits.endIndex, offsetBy: -drop)]
            guard var kept = Int(keep.isEmpty ? "0" : keep) else { return nil }
            if let d = firstDropped.wholeNumberValue, d >= 5 { kept += 1 }
            digits = String(kept)
            scale = Self.maxScale
        }
        guard let magnitude = Int(digits.isEmpty ? "0" : digits) else { return nil }
        self.units = negative ? -magnitude : magnitude
        self.scale = scale
    }

    /// Whatever numeric shape a runtime value has, as an exact amount.
    ///
    /// `nil` when the value is not a number — the caller reports that, since
    /// only it knows which statement asked.
    public static func from(_ value: any Sendable) -> AROCurrency? {
        if let c = value as? AROCurrency { return c }
        if let i = value as? Int { return AROCurrency(i) }
        if let d = value as? Double { return AROCurrency(d) }
        if let f = value as? Float { return AROCurrency(Double(f)) }
        if let s = value as? String { return AROCurrency(decimalString: s) }
        return nil
    }

    // MARK: - Conversion out

    /// The nearest `Double`. Lossy by definition — for boundaries that only
    /// speak IEEE 754, never for arithmetic.
    public var doubleValue: Double {
        Double(units) / Self.pow10Double(scale)
    }

    /// The exact decimal spelling, at this amount's own scale.
    ///
    /// `7.20` is `"7.20"` when it was computed from two-decimal inputs and
    /// `"7.2"` when it was computed from one — the scale is carried from the
    /// operands rather than invented, which is the same rule `BigDecimal` and
    /// SQL `NUMERIC` follow. Use `fixed` to settle on a presentation scale.
    public var description: String {
        guard scale > 0 else { return String(units) }
        let negative = units < 0
        var digits = String(units.magnitude)
        if digits.count <= scale {
            digits = String(repeating: "0", count: scale - digits.count + 1) + digits
        }
        let splitIndex = digits.index(digits.endIndex, offsetBy: -scale)
        let whole = String(digits[digits.startIndex..<splitIndex])
        let frac = String(digits[splitIndex...])
        return (negative ? "-" : "") + whole + "." + frac
    }

    // MARK: - Scaling

    /// This amount at `target` decimal places, rounding half-up away from zero.
    ///
    /// Half-up is the rule invoices are written with: `2.345` at two places is
    /// `2.35`, and `-2.345` is `-2.35`. Banker's rounding is the better choice
    /// for summing many independent amounts, and is not what a reader checking
    /// one line against a receipt expects.
    public func rescaled(to target: Int) throws -> AROCurrency {
        let target = max(0, Swift.min(target, Self.maxScale))
        if target == scale { return self }
        if target > scale {
            guard let factor = Self.pow10(target - scale) else {
                throw AROCurrencyError.overflow("rescale to \(target) places")
            }
            let (value, overflow) = units.multipliedReportingOverflow(by: factor)
            guard !overflow else { throw AROCurrencyError.overflow("rescale to \(target) places") }
            return AROCurrency(units: value, scale: target)
        }
        guard let divisor = Self.pow10(scale - target) else {
            throw AROCurrencyError.overflow("rescale to \(target) places")
        }
        let quotient = units / divisor
        let remainder = units % divisor
        if remainder.magnitude * 2 >= divisor.magnitude {
            let step = units < 0 ? -1 : 1
            let (value, overflow) = quotient.addingReportingOverflow(step)
            guard !overflow else { throw AROCurrencyError.overflow("rescale to \(target) places") }
            return AROCurrency(units: value, scale: target)
        }
        return AROCurrency(units: quotient, scale: target)
    }

    /// Trailing zeros dropped, never below `floor` places.
    ///
    /// Keeps the scale from creeping upward through a pipeline — `6.00 / 2` is
    /// computed at six places and reported as `3.00`, not `3.000000`.
    public func normalized(floor: Int = 0) -> AROCurrency {
        var units = self.units
        var scale = self.scale
        let floor = max(0, floor)
        while scale > floor, units % 10 == 0, units != 0 {
            units /= 10
            scale -= 1
        }
        if units == 0 { return AROCurrency(units: 0, scale: floor) }
        return AROCurrency(units: units, scale: scale)
    }

    // MARK: - Arithmetic

    public func adding(_ other: AROCurrency) throws -> AROCurrency {
        let (l, r, scale) = try Self.aligned(self, other, "+")
        let (value, overflow) = l.addingReportingOverflow(r)
        guard !overflow else { throw AROCurrencyError.overflow("\(self) + \(other)") }
        return AROCurrency(units: value, scale: scale)
    }

    public func subtracting(_ other: AROCurrency) throws -> AROCurrency {
        let (l, r, scale) = try Self.aligned(self, other, "-")
        let (value, overflow) = l.subtractingReportingOverflow(r)
        guard !overflow else { throw AROCurrencyError.overflow("\(self) - \(other)") }
        return AROCurrency(units: value, scale: scale)
    }

    /// Exact: the scales add, so three items at `2.40` is `7.20` and not a
    /// rounding of it.
    public func multiplied(by other: AROCurrency) throws -> AROCurrency {
        let scale = self.scale + other.scale
        guard scale <= Self.maxScale else {
            throw AROCurrencyError.scaleExceeded("\(self) * \(other)", scale)
        }
        let (value, overflow) = units.multipliedReportingOverflow(by: other.units)
        guard !overflow else { throw AROCurrencyError.overflow("\(self) * \(other)") }
        return AROCurrency(units: value, scale: scale).normalized(floor: Swift.max(self.scale, other.scale))
    }

    /// Division, with the rounding stated rather than silent.
    ///
    /// Computed at ``divisionScale`` decimal places, rounded half-up, then
    /// trailing zeros dropped down to the wider of the two operands' scales.
    /// So `6.00 / 2` is `3.00` and `10.00 / 3` is `3.333333` — close enough
    /// that no currency's minor unit is decided here, and visibly not exact,
    /// which is the honest report.
    public func divided(by other: AROCurrency) throws -> AROCurrency {
        guard other.units != 0 else { throw AROCurrencyError.divisionByZero }
        let floor = Swift.max(scale, other.scale)
        let shift = Self.divisionScale + other.scale - scale

        var numerator = units
        var denominator = other.units
        if shift >= 0 {
            guard let factor = Self.pow10(shift) else {
                throw AROCurrencyError.overflow("\(self) / \(other)")
            }
            let (value, overflow) = numerator.multipliedReportingOverflow(by: factor)
            guard !overflow else { throw AROCurrencyError.overflow("\(self) / \(other)") }
            numerator = value
        } else {
            guard let factor = Self.pow10(-shift) else {
                throw AROCurrencyError.overflow("\(self) / \(other)")
            }
            let (value, overflow) = denominator.multipliedReportingOverflow(by: factor)
            guard !overflow else { throw AROCurrencyError.overflow("\(self) / \(other)") }
            denominator = value
        }

        var quotient = numerator / denominator
        let remainder = numerator % denominator
        if remainder.magnitude * 2 >= denominator.magnitude {
            let step = (numerator < 0) == (denominator < 0) ? 1 : -1
            let (value, overflow) = quotient.addingReportingOverflow(step)
            guard !overflow else { throw AROCurrencyError.overflow("\(self) / \(other)") }
            quotient = value
        }
        return AROCurrency(units: quotient, scale: Self.divisionScale).normalized(floor: floor)
    }

    /// The remainder, at the aligned scale. Exact.
    public func remainder(dividingBy other: AROCurrency) throws -> AROCurrency {
        guard other.units != 0 else { throw AROCurrencyError.divisionByZero }
        let (l, r, scale) = try Self.aligned(self, other, "%")
        return AROCurrency(units: l % r, scale: scale)
    }

    public var negated: AROCurrency {
        AROCurrency(units: -units, scale: scale)
    }

    /// `-1`, `0` or `1`, comparing exactly.
    public func compare(_ other: AROCurrency) -> Int {
        if let (l, r, _) = try? Self.aligned(self, other, "compare") {
            return l < r ? -1 : (l > r ? 1 : 0)
        }
        // Alignment only fails when the two scales differ by more than an Int
        // can bridge, which means the magnitudes differ by 10^18 or more. The
        // Double comparison is then nowhere near a tie.
        let l = doubleValue, r = other.doubleValue
        return l < r ? -1 : (l > r ? 1 : 0)
    }

    // MARK: - Internals

    /// The two amounts as integers at a common scale.
    private static func aligned(
        _ a: AROCurrency, _ b: AROCurrency, _ symbol: String
    ) throws -> (Int, Int, Int) {
        if a.scale == b.scale { return (a.units, b.units, a.scale) }
        let scale = Swift.max(a.scale, b.scale)
        func lift(_ value: AROCurrency) throws -> Int {
            guard let factor = pow10(scale - value.scale) else {
                throw AROCurrencyError.overflow("\(a) \(symbol) \(b)")
            }
            let (lifted, overflow) = value.units.multipliedReportingOverflow(by: factor)
            guard !overflow else { throw AROCurrencyError.overflow("\(a) \(symbol) \(b)") }
            return lifted
        }
        return (try lift(a), try lift(b), scale)
    }

    /// `10^n` as an `Int`, or `nil` when it does not fit.
    static func pow10(_ n: Int) -> Int? {
        guard n >= 0 else { return nil }
        guard n < powers.count else { return nil }
        return powers[n]
    }

    private static func pow10Double(_ n: Int) -> Double {
        guard let exact = pow10(n) else { return Foundation.pow(10.0, Double(n)) }
        return Double(exact)
    }

    private static let powers: [Int] = {
        var result: [Int] = [1]
        var value = 1
        for _ in 1...18 {
            value *= 10
            result.append(value)
        }
        return result
    }()
}

// MARK: - Protocol conformances

extension AROCurrency: CustomStringConvertible {}

extension AROCurrency: Equatable, Hashable, Comparable {
    /// Value equality, not representation equality: `7.2 == 7.20`.
    public static func == (lhs: AROCurrency, rhs: AROCurrency) -> Bool {
        lhs.compare(rhs) == 0
    }

    public static func < (lhs: AROCurrency, rhs: AROCurrency) -> Bool {
        lhs.compare(rhs) < 0
    }

    /// Hashes the fully normalised form, so `7.2` and `7.20` — which are
    /// equal — also land in the same bucket.
    public func hash(into hasher: inout Hasher) {
        let n = normalized()
        hasher.combine(n.units)
        hasher.combine(n.scale)
    }
}

// MARK: - Errors

/// An exact amount that cannot be represented, named by the operation that
/// asked for it. Never a wrapped or quietly rounded result (GitLab #906).
public enum AROCurrencyError: Error, CustomStringConvertible, Sendable {
    case overflow(String)
    case scaleExceeded(String, Int)
    case divisionByZero
    case notANumber(String)

    public var description: String {
        switch self {
        case .overflow(let what):
            return "Currency overflow in \(what)"
        case .scaleExceeded(let what, let scale):
            return "Currency needs \(scale) decimal places in \(what), "
                + "and carries at most \(AROCurrency.maxScale)"
        case .divisionByZero:
            return "Division by zero"
        case .notANumber(let what):
            return "Cannot read \(what) as an exact amount"
        }
    }

    public var localizedDescription: String { description }
}
