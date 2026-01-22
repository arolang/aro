// ============================================================
// SemanticTokensHandler.swift
// AROLSP - Semantic Tokens Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/semanticTokens requests
public struct SemanticTokensHandler: Sendable {

    // Token types supported
    private static let tokenTypes = [
        "namespace",    // 0 - Feature set business activity
        "type",         // 1 - Type annotations
        "class",        // 2
        "enum",         // 3
        "interface",    // 4
        "struct",       // 5
        "typeParameter",// 6
        "parameter",    // 7
        "variable",     // 8 - Variables/results/objects
        "property",     // 9 - Qualifiers
        "enumMember",   // 10
        "event",        // 11 - Events
        "function",     // 12 - Feature set names
        "method",       // 13 - Actions
        "macro",        // 14
        "keyword",      // 15 - Articles, prepositions
        "modifier",     // 16
        "comment",      // 17 - Comments
        "string",       // 18 - String literals
        "number",       // 19 - Number literals
        "regexp",       // 20 - Regex literals
        "operator",     // 21 - Operators
    ]

    // Token modifiers supported
    private static let tokenModifiers = [
        "declaration",  // 0
        "definition",   // 1
        "readonly",     // 2
        "static",       // 3
        "deprecated",   // 4
        "abstract",     // 5
        "async",        // 6
        "modification", // 7
        "documentation",// 8
        "defaultLibrary"// 9
    ]

    public init() {}

    /// Get the token legend for capability advertisement
    public var legend: [String: Any] {
        return [
            "tokenTypes": Self.tokenTypes,
            "tokenModifiers": Self.tokenModifiers
        ]
    }

    /// Handle a semantic tokens request
    public func handle(
        content: String,
        compilationResult: CompilationResult?
    ) -> [String: Any]? {
        guard let result = compilationResult else { return nil }

        var tokens: [(line: Int, char: Int, length: Int, type: Int, modifiers: Int)] = []

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            // Feature set name token
            tokens.append((
                line: fs.span.start.line - 1,
                char: fs.span.start.column,  // After the (
                length: fs.name.count,
                type: 12,  // function
                modifiers: 1  // definition
            ))

            // Business activity token
            // Find the colon position to locate business activity
            let businessActivityStart = fs.span.start.column + fs.name.count + 2  // name + ": "
            tokens.append((
                line: fs.span.start.line - 1,
                char: businessActivityStart,
                length: fs.businessActivity.count,
                type: 0,  // namespace
                modifiers: 0
            ))

            // Process statements
            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    // Action token
                    tokens.append((
                        line: aro.action.span.start.line - 1,
                        char: aro.action.span.start.column,
                        length: aro.action.verb.count,
                        type: 13,  // method
                        modifiers: 0
                    ))

                    // Result token
                    tokens.append((
                        line: aro.result.span.start.line - 1,
                        char: aro.result.span.start.column,
                        length: aro.result.base.count,
                        type: 8,  // variable
                        modifiers: 1  // definition
                    ))

                    // Result qualifier if present
                    if !aro.result.specifiers.isEmpty {
                        let qualifier = aro.result.specifiers[0]
                        let qualifierStart = aro.result.span.start.column + aro.result.base.count + 2  // base + ": "
                        tokens.append((
                            line: aro.result.span.start.line - 1,
                            char: qualifierStart,
                            length: qualifier.count,
                            type: 9,  // property
                            modifiers: 0
                        ))
                    }

                    // Object noun token
                    tokens.append((
                        line: aro.object.noun.span.start.line - 1,
                        char: aro.object.noun.span.start.column,
                        length: aro.object.noun.base.count,
                        type: 8,  // variable
                        modifiers: 0
                    ))

                    // Object qualifier if present
                    if !aro.object.noun.specifiers.isEmpty {
                        let qualifier = aro.object.noun.specifiers[0]
                        let qualifierStart = aro.object.noun.span.start.column + aro.object.noun.base.count + 2
                        tokens.append((
                            line: aro.object.noun.span.start.line - 1,
                            char: qualifierStart,
                            length: qualifier.count,
                            type: 9,  // property
                            modifiers: 0
                        ))
                    }

                    // Add tokens for expressions
                    if let expr = aro.valueSource.asExpression {
                        tokens.append(contentsOf: tokenizeExpression(expr))
                    }
                }

                if let publish = statement as? PublishStatement {
                    // External name
                    tokens.append((
                        line: publish.span.start.line - 1,
                        char: publish.span.start.column + 13,  // "Publish> as <"
                        length: publish.externalName.count,
                        type: 8,  // variable
                        modifiers: 1  // definition
                    ))

                    // Internal variable
                    tokens.append((
                        line: publish.span.start.line - 1,
                        char: publish.span.start.column + 15 + publish.externalName.count,
                        length: publish.internalVariable.count,
                        type: 8,  // variable
                        modifiers: 0
                    ))
                }
            }
        }

        // Sort tokens by position
        tokens.sort { ($0.line, $0.char) < ($1.line, $1.char) }

        // Encode as delta format
        var data: [Int] = []
        var prevLine = 0
        var prevChar = 0

        for token in tokens {
            let deltaLine = token.line - prevLine
            let deltaChar = deltaLine == 0 ? token.char - prevChar : token.char

            data.append(deltaLine)
            data.append(deltaChar)
            data.append(token.length)
            data.append(token.type)
            data.append(token.modifiers)

            prevLine = token.line
            prevChar = token.char
        }

        return ["data": data]
    }

    // MARK: - Expression Tokenization

    private func tokenizeExpression(_ expression: any AROParser.Expression) -> [(line: Int, char: Int, length: Int, type: Int, modifiers: Int)] {
        var tokens: [(line: Int, char: Int, length: Int, type: Int, modifiers: Int)] = []

        if let varRef = expression as? VariableRefExpression {
            tokens.append((
                line: varRef.span.start.line - 1,
                char: varRef.span.start.column,
                length: varRef.noun.base.count,
                type: 8,  // variable
                modifiers: 0
            ))
        } else if let literal = expression as? LiteralExpression {
            let type: Int
            switch literal.value {
            case .string:
                type = 18  // string
            case .integer, .float:
                type = 19  // number
            case .regex:
                type = 20  // regexp
            default:
                type = 8  // variable for others
            }
            tokens.append((
                line: literal.span.start.line - 1,
                char: literal.span.start.column,
                length: literal.span.end.column - literal.span.start.column,
                type: type,
                modifiers: 0
            ))
        } else if let binary = expression as? BinaryExpression {
            tokens.append(contentsOf: tokenizeExpression(binary.left))
            // Operator token
            tokens.append((
                line: binary.span.start.line - 1,
                char: (binary.left.span.end.column + binary.right.span.start.column) / 2,
                length: 1,
                type: 21,  // operator
                modifiers: 0
            ))
            tokens.append(contentsOf: tokenizeExpression(binary.right))
        } else if let unary = expression as? UnaryExpression {
            tokens.append(contentsOf: tokenizeExpression(unary.operand))
        } else if let member = expression as? MemberAccessExpression {
            tokens.append(contentsOf: tokenizeExpression(member.base))
            tokens.append((
                line: member.span.start.line - 1,
                char: member.span.end.column - member.member.count,
                length: member.member.count,
                type: 9,  // property
                modifiers: 0
            ))
        } else if let subscript_ = expression as? SubscriptExpression {
            tokens.append(contentsOf: tokenizeExpression(subscript_.base))
            tokens.append(contentsOf: tokenizeExpression(subscript_.index))
        } else if let array = expression as? ArrayLiteralExpression {
            for element in array.elements {
                tokens.append(contentsOf: tokenizeExpression(element))
            }
        } else if let map = expression as? MapLiteralExpression {
            for entry in map.entries {
                tokens.append(contentsOf: tokenizeExpression(entry.value))
            }
        }

        return tokens
    }
}

#endif
