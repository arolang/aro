// ============================================================
// ExpressionSerializer.swift
// ARO Compiler - Expression / literal / pattern JSON serialization
// ============================================================

#if !os(Windows)
import Foundation
import AROParser

/// Serializes ARO AST expressions, literals, and match patterns into the
/// JSON string forms the runtime bridge parses at execution time.
///
/// This is a pure, stateless component: every method maps AST → String with
/// no dependency on LLVM module state. Extracted from `LLVMCodeGenerator`
/// (issue #334) so expression serialization lives in one place.
struct ExpressionSerializer {

    // MARK: - Expression Serialization

    func serializeExpression(_ expr: any AROParser.Expression) -> String {
        // GitLab #102: Constant folding optimization
        // If the expression is entirely constant, evaluate it at compile time
        if ConstantFolder.isConstant(expr), let value = ConstantFolder.evaluate(expr) {
            return serializeLiteralValue(value)
        }

        if let literal = expr as? LiteralExpression {
            return serializeLiteralValue(literal.value)
        } else if let ref = expr as? VariableRefExpression {
            return serializeVariableRef(ref)
        } else if let binary = expr as? BinaryExpression {
            return """
            {"$binary":{"op":"\(binary.op.rawValue)","left":\(serializeExpression(binary.left)),"right":\(serializeExpression(binary.right))}}
            """
        } else if let unary = expr as? UnaryExpression {
            return """
            {"$unary":{"op":"\(unary.op.rawValue)","operand":\(serializeExpression(unary.operand))}}
            """
        } else if let interpolated = expr as? InterpolatedStringExpression {
            return serializeInterpolatedString(interpolated.parts)
        } else if let array = expr as? ArrayLiteralExpression {
            return serializeArrayLiteral(array.elements)
        } else if let map = expr as? MapLiteralExpression {
            return serializeMapLiteral(map.entries)
        } else if let member = expr as? MemberAccessExpression {
            return """
            {"$member":{"base":\(serializeExpression(member.base)),"member":"\(member.member)"}}
            """
        } else if let subscript_ = expr as? SubscriptExpression {
            return """
            {"$subscript":{"base":\(serializeExpression(subscript_.base)),"index":\(serializeExpression(subscript_.index))}}
            """
        } else if let grouped = expr as? GroupedExpression {
            return serializeExpression(grouped.expression)
        } else if let existence = expr as? ExistenceExpression {
            return """
            {"$exists":\(serializeExpression(existence.expression))}
            """
        } else if let typeCheck = expr as? TypeCheckExpression {
            return """
            {"$typeCheck":{"expr":\(serializeExpression(typeCheck.expression)),"type":"\(typeCheck.typeName)"}}
            """
        }
        return "{\"$unknown\":true}"
    }

    func serializeLiteralValue(_ lit: LiteralValue) -> String {
        switch lit {
        case .string(let s):
            return "{\"$lit\":\"\(escapeJSON(s))\"}"
        case .integer(let i):
            return "{\"$lit\":\(i)}"
        case .float(let f):
            return "{\"$lit\":\(f)}"
        case .boolean(let b):
            return "{\"$lit\":\(b)}"
        case .null:
            return "{\"$lit\":null}"
        case .array(let elements):
            return serializeLiteralArray(elements)
        case .object(let entries):
            return serializeLiteralObject(entries)
        case .regex(let pattern, let flags):
            return "{\"$regex\":{\"pattern\":\"\(escapeJSON(pattern))\",\"flags\":\"\(flags)\"}}"
        }
    }

    func serializeVariableRef(_ ref: VariableRefExpression) -> String {
        var result = "{\"$var\":\"\(ref.noun.base)\""
        if !ref.noun.specifiers.isEmpty {
            let specs = ref.noun.specifiers.map { "\"\($0)\"" }.joined(separator: ",")
            result += ",\"$specs\":[\(specs)]"
        }
        result += "}"
        return result
    }

    func serializeInterpolatedString(_ parts: [StringPart]) -> String {
        var template = ""
        for part in parts {
            switch part {
            case .literal(let s):
                template += escapeJSON(s)
            case .interpolation(let expr):
                // Serialize the expression and embed it
                if let varRef = expr as? VariableRefExpression {
                    // Include specifiers for property access: <base: spec1: spec2>
                    if varRef.noun.specifiers.isEmpty {
                        template += "${<\(varRef.noun.base)>}"
                    } else {
                        let specifiers = varRef.noun.specifiers.joined(separator: ": ")
                        template += "${<\(varRef.noun.base): \(specifiers)>}"
                    }
                } else {
                    template += "${...}"
                }
            }
        }
        return "{\"$interpolated\":\"\(template)\"}"
    }

    func serializeArrayLiteral(_ elements: [any AROParser.Expression]) -> String {
        let serialized = elements.map { serializeExpression($0) }.joined(separator: ",")
        return "[\(serialized)]"
    }

    func serializeMapLiteral(_ entries: [MapEntry]) -> String {
        let serialized = entries.map { entry in
            "\"\(escapeJSON(entry.key))\":\(serializeExpression(entry.value))"
        }.joined(separator: ",")
        return "{\(serialized)}"
    }

    func serializeLiteralArray(_ elements: [LiteralValue]) -> String {
        let serialized = elements.map { serializeLiteralValue($0) }.joined(separator: ",")
        return "[\(serialized)]"
    }

    func serializeLiteralObject(_ entries: [(String, LiteralValue)]) -> String {
        let serialized = entries.map { key, value in
            "\"\(escapeJSON(key))\":\(serializeLiteralValue(value))"
        }.joined(separator: ",")
        return "{\(serialized)}"
    }

    // MARK: - Plain (unwrapped) Literal Serialization

    // Plain JSON serialization (no $lit wrappers) for variableBindDict/variableBindArray
    func serializeLiteralValuePlain(_ lit: LiteralValue) -> String {
        switch lit {
        case .string(let s):
            return "\"\(escapeJSON(s))\""
        case .integer(let i):
            return "\(i)"
        case .float(let f):
            return "\(f)"
        case .boolean(let b):
            return "\(b)"
        case .null:
            return "null"
        case .array(let elements):
            return serializeLiteralArrayPlain(elements)
        case .object(let entries):
            return serializeLiteralObjectPlain(entries)
        case .regex(let pattern, let flags):
            return "\"/\(escapeJSON(pattern))/\(flags)\""
        }
    }

    func serializeLiteralArrayPlain(_ elements: [LiteralValue]) -> String {
        let serialized = elements.map { serializeLiteralValuePlain($0) }.joined(separator: ",")
        return "[\(serialized)]"
    }

    func serializeLiteralObjectPlain(_ entries: [(String, LiteralValue)]) -> String {
        let serialized = entries.map { key, value in
            "\"\(escapeJSON(key))\":\(serializeLiteralValuePlain(value))"
        }.joined(separator: ",")
        return "{\(serialized)}"
    }

    // MARK: - Match Statement Serialization

    func serializeMatchSubject(_ subject: QualifiedNoun) -> String {
        let specsJSON = subject.specifiers.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",")
        return "{\"name\":\"\(escapeJSON(subject.base))\",\"specifiers\":[\(specsJSON)]}"
    }

    /// Serialize a pattern to JSON for match statement
    func serializePattern(_ pattern: Pattern) -> String {
        switch pattern {
        case .literal(let literal):
            return "{\"type\":\"literal\",\"value\":\(serializePatternLiteral(literal))}"
        case .variable(let noun):
            return "{\"type\":\"variable\",\"name\":\"\(escapeJSON(noun.base))\"}"
        case .wildcard:
            return "{\"type\":\"wildcard\"}"
        case .regex(let patternStr, let flags):
            return "{\"type\":\"regex\",\"pattern\":\"\(escapeJSON(patternStr))\",\"flags\":\"\(escapeJSON(flags))\"}"
        }
    }

    /// Serialize a literal value to raw JSON (for pattern matching)
    func serializePatternLiteral(_ literal: LiteralValue) -> String {
        switch literal {
        case .string(let s):
            return "\"\(escapeJSON(s))\""
        case .integer(let i):
            return "\(i)"
        case .float(let f):
            return "\(f)"
        case .boolean(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        case .array(let elements):
            let items = elements.map { serializePatternLiteral($0) }.joined(separator: ",")
            return "[\(items)]"
        case .object(let entries):
            let items = entries.map { (key, value) in "\"\(escapeJSON(key))\":\(serializePatternLiteral(value))" }.joined(separator: ",")
            return "{\(items)}"
        case .regex(let pattern, let flags):
            return "{\"pattern\":\"\(escapeJSON(pattern))\",\"flags\":\"\(escapeJSON(flags))\"}"
        }
    }

    // MARK: - JSON Escaping

    func escapeJSON(_ s: String) -> String {
        var result = ""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x5C: result += "\\\\"          // backslash
            case 0x22: result += "\\\""          // double quote
            case 0x0A: result += "\\n"           // newline
            case 0x0D: result += "\\r"           // carriage return
            case 0x09: result += "\\t"           // tab
            case 0x00..<0x20:                    // other control characters (incl. ESC 0x1B)
                result += String(format: "\\u%04x", scalar.value)
            default:
                result += String(scalar)
            }
        }
        return result
    }
}

#endif
