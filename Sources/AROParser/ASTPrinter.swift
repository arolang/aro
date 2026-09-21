// ============================================================
// ASTPrinter.swift
// ARO Parser - AST Pretty Printer
// ============================================================
//
// Lifted out of AST.swift, which had grown to hold both the tree and one
// of its consumers. The printer is a visitor like any other; it does not
// need to live beside the node definitions to see them.

import Foundation

// MARK: - AST Pretty Printer

/// Prints the AST in a readable format
public struct ASTPrinter: ASTVisitor {
    public typealias Result = String
    
    private var indent: Int = 0
    
    public init() {}

    /// Renders a child node with this printer's settings.
    ///
    /// `ASTNode.accept` is declared `throws` for visitors that can fail. None
    /// of this printer's `visit` methods can — they all return a `String`
    /// unconditionally — so the failure branch is unreachable, and the empty
    /// string it falls back to is never produced. That reasoning used to be
    /// absent and repeated 22 times as a bare `(try? …) ?? ""`; it is written
    /// down once, here, instead.
    fileprivate func render(_ node: any ASTNode) -> String {
        (try? node.accept(self)) ?? ""
    }
    
    private func indentation() -> String {
        String(repeating: "  ", count: indent)
    }
    
    public func visit(_ node: Program) -> String {
        var result = "Program\n"
        var printer = self
        printer.indent += 1
        for importDecl in node.imports {
            result += printer.render(importDecl)
        }
        for featureSet in node.featureSets {
            result += printer.render(featureSet)
        }
        return result
    }

    public func visit(_ node: ImportDeclaration) -> String {
        "\(indentation())Import: \(node.path)\n"
    }

    public func visit(_ node: FeatureSet) -> String {
        var result = "\(indentation())FeatureSet: \(node.name)\n"
        result += "\(indentation())  BusinessActivity: \(node.businessActivity)\n"
        
        var printer = self
        printer.indent += 1
        for statement in node.statements {
            result += printer.render(statement)
        }
        return result
    }
    
    public func visit(_ node: AROStatement) -> String {
        var result = "\(indentation())AROStatement\n"
        result += "\(indentation())  Action: \(node.action.verb) [\(node.action.semanticRole)]\n"
        result += "\(indentation())  Result: \(node.result.fullName)\n"
        result += "\(indentation())  Object: \(node.object.preposition.rawValue) \(node.object.noun.fullName)\n"
        return result
    }
    
    public func visit(_ node: PublishStatement) -> String {
        var result = "\(indentation())PublishStatement\n"
        result += "\(indentation())  External: \(node.externalName)\n"
        result += "\(indentation())  Internal: \(node.internalVariable)\n"
        return result
    }

    public func visit(_ node: RequireStatement) -> String {
        var result = "\(indentation())RequireStatement\n"
        result += "\(indentation())  Variable: \(node.variableName)\n"
        result += "\(indentation())  Source: \(node.source)\n"
        return result
    }

    public func visit(_ node: WhenStatement) -> String {
        var result = "\(indentation())WhenStatement\n"
        result += "\(indentation())  Condition: \(node.condition)\n"
        result += "\(indentation())  Body: \(node.body.count) statements\n"
        return result
    }

    public func visit(_ node: MatchStatement) -> String {
        var result = "\(indentation())MatchStatement\n"
        result += "\(indentation())  Subject: <\(node.subject.fullName)>\n"
        var printer = self
        printer.indent += 1
        for caseClause in node.cases {
            result += "\(printer.indentation())Case: \(caseClause.pattern)\n"
            if let guard_ = caseClause.guardCondition {
                result += "\(printer.indentation())  Guard: \(guard_)\n"
            }
            var bodyPrinter = printer
            bodyPrinter.indent += 1
            for statement in caseClause.body {
                result += bodyPrinter.render(statement)
            }
        }
        if let otherwise = node.otherwise {
            result += "\(printer.indentation())Otherwise:\n"
            var otherwisePrinter = printer
            otherwisePrinter.indent += 1
            for statement in otherwise {
                result += otherwisePrinter.render(statement)
            }
        }
        return result
    }

    public func visit(_ node: ForEachLoop) -> String {
        var result = "\(indentation())ForEachLoop\n"
        result += "\(indentation())  Item: <\(node.itemVariable)>\n"
        if let index = node.indexVariable {
            result += "\(indentation())  Index: <\(index)>\n"
        }
        result += "\(indentation())  Collection: \(node.collectionLabel)\n"
        result += "\(indentation())  Parallel: \(node.isParallel)\n"
        if let concurrency = node.concurrency {
            result += "\(indentation())  Concurrency: \(concurrency)\n"
        }
        if let filter = node.filter {
            result += "\(indentation())  Filter: \(filter)\n"
        }
        var printer = self
        printer.indent += 1
        result += "\(indentation())  Body:\n"
        for statement in node.body {
            result += printer.render(statement)
        }
        return result
    }

    public func visit(_ node: WhileLoop) -> String {
        var result = "\(indentation())WhileLoop\n"
        result += "\(indentation())  Condition: \(node.condition)\n"
        var printer = self
        printer.indent += 1
        result += "\(indentation())  Body:\n"
        for statement in node.body {
            result += printer.render(statement)
        }
        return result
    }

    public func visit(_ node: BreakStatement) -> String {
        return "\(indentation())BreakStatement\n"
    }

    public func visit(_ node: RangeLoop) -> String {
        var result = "\(indentation())RangeLoop\n"
        result += "\(indentation())  Variable: <\(node.variable)>\n"
        result += "\(indentation())  From: \(node.from.description)\n"
        result += "\(indentation())  To: \(node.to.description)\n"
        var printer = self
        printer.indent += 1
        result += "\(indentation())  Body:\n"
        for statement in node.body {
            result += printer.render(statement)
        }
        return result
    }

    public func visit(_ node: PipelineStatement) -> String {
        var result = "\(indentation())PipelineStatement\n"
        result += "\(indentation())  Stages: \(node.stages.count)\n"

        var printer = self
        printer.indent += 1
        for (index, stage) in node.stages.enumerated() {
            result += "\(printer.indentation())Stage \(index + 1):\n"
            var stagePrinter = printer
            stagePrinter.indent += 1
            result += stagePrinter.render(stage)
        }

        return result
    }

    public func visit(_ node: ErrorStatement) -> String {
        "\(indentation())ErrorStatement: \(node.message)\n"
    }

    // Expression visitors
    public func visit(_ node: LiteralExpression) -> String {
        "\(indentation())Literal: \(node.value)\n"
    }

    public func visit(_ node: ArrayLiteralExpression) -> String {
        var result = "\(indentation())Array[\(node.elements.count)]\n"
        var printer = self
        printer.indent += 1
        for element in node.elements {
            result += printer.render(element)
        }
        return result
    }

    public func visit(_ node: MapLiteralExpression) -> String {
        var result = "\(indentation())Map{\(node.entries.count)}\n"
        var printer = self
        printer.indent += 1
        for entry in node.entries {
            result += "\(printer.indentation())\(entry.key):\n"
            printer.indent += 1
            result += printer.render(entry.value)
            printer.indent -= 1
        }
        return result
    }

    public func visit(_ node: VariableRefExpression) -> String {
        "\(indentation())VarRef: <\(node.noun.fullName)>\n"
    }

    public func visit(_ node: BinaryExpression) -> String {
        var result = "\(indentation())Binary: \(node.op.rawValue)\n"
        var printer = self
        printer.indent += 1
        result += printer.render(node.left)
        result += printer.render(node.right)
        return result
    }

    public func visit(_ node: UnaryExpression) -> String {
        var result = "\(indentation())Unary: \(node.op.rawValue)\n"
        var printer = self
        printer.indent += 1
        result += printer.render(node.operand)
        return result
    }

    public func visit(_ node: MemberAccessExpression) -> String {
        var result = "\(indentation())MemberAccess: .\(node.member)\n"
        var printer = self
        printer.indent += 1
        result += printer.render(node.base)
        return result
    }

    public func visit(_ node: SubscriptExpression) -> String {
        var result = "\(indentation())Subscript\n"
        var printer = self
        printer.indent += 1
        result += "\(printer.indentation())base:\n"
        printer.indent += 1
        result += printer.render(node.base)
        printer.indent -= 1
        result += "\(printer.indentation())index:\n"
        printer.indent += 1
        result += printer.render(node.index)
        return result
    }

    public func visit(_ node: GroupedExpression) -> String {
        var result = "\(indentation())Grouped\n"
        var printer = self
        printer.indent += 1
        result += printer.render(node.expression)
        return result
    }

    public func visit(_ node: ExistenceExpression) -> String {
        var result = "\(indentation())Exists\n"
        var printer = self
        printer.indent += 1
        result += printer.render(node.expression)
        return result
    }

    public func visit(_ node: TypeCheckExpression) -> String {
        var result = "\(indentation())TypeCheck: \(node.typeName)\n"
        var printer = self
        printer.indent += 1
        result += printer.render(node.expression)
        return result
    }

    public func visit(_ node: EmptinessCheckExpression) -> String {
        var result = "\(indentation())EmptinessCheck\(node.negated ? " (not)" : "")\n"
        var printer = self
        printer.indent += 1
        result += printer.render(node.expression)
        return result
    }

    public func visit(_ node: InterpolatedStringExpression) -> String {
        var result = "\(indentation())InterpolatedString[\(node.parts.count) parts]\n"
        var printer = self
        printer.indent += 1
        for part in node.parts {
            switch part {
            case .literal(let s):
                result += "\(printer.indentation())literal: \"\(s)\"\n"
            case .interpolation(let expr):
                result += "\(printer.indentation())interpolation:\n"
                printer.indent += 1
                result += printer.render(expr)
                printer.indent -= 1
            }
        }
        return result
    }
}
