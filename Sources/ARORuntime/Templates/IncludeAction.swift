// ============================================================
// IncludeAction.swift
// ARO Runtime - Include Action for Templates (ARO-0045)
// ============================================================

import Foundation
import AROParser

/// Includes another template within a template (ARO-0045)
///
/// This action is only valid within template execution blocks.
/// It renders the included template and appends the result to the
/// current template's output buffer.
///
/// ## Syntax
/// ```aro
/// {{ <Include> the <template: partial/header.tpl>. }}
/// ```
///
/// ## With Variable Overrides
/// ```aro
/// {{ <Include> the <template: user-card.tpl> with { user: <currentUser> }. }}
/// ```
public struct IncludeAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["include", "embed", "insert"]
    public static let validPrepositions: Set<Preposition> = [.with, .from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get template path from object base or specifiers
        let templatePath: String

        // Check if object.base is "template" with path in specifiers
        if object.base.lowercased() == "template" {
            guard !object.specifiers.isEmpty else {
                throw ActionError.runtimeError("Include requires template path: <template: path>")
            }

            // Join specifiers with '.' to reconstruct path with extension
            // (specifiers are split by ':' and '.', so "foo.tpl" becomes ["foo", "tpl"])
            let rawPath = object.specifiers.joined(separator: ".")

            // Check if this is a single-part variable reference that should be resolved
            if object.specifiers.count == 1, let resolved: String = context.resolve(object.specifiers[0]) {
                templatePath = resolved
            } else {
                templatePath = rawPath
            }
        } else {
            // Legacy: path directly in object.base
            templatePath = object.base
        }

        // Get template service
        guard let templateService = context.service(TemplateService.self) else {
            throw ActionError.missingService("TemplateService not registered. Include requires the template service to be configured.")
        }

        // Create a child context for the included template
        guard let runtimeContext = context as? RuntimeContext else {
            throw ActionError.runtimeError("Invalid context type for template include")
        }

        let includeContext = runtimeContext.createTemplateContext()

        // Apply any variable overrides from the "with" clause
        if let withData = context.resolveAny("_with_") as? [String: any Sendable] {
            for (key, value) in withData {
                includeContext.bind(key, value: value, allowRebind: true)
            }
        }

        // Also check _literal_ for inline object literals
        if let literal = context.resolveAny("_literal_") as? [String: any Sendable] {
            for (key, value) in literal {
                includeContext.bind(key, value: value, allowRebind: true)
            }
        }

        // Register the template service in the child context
        includeContext.register(templateService)

        // Render the included template
        let rendered = try await templateService.render(path: templatePath, context: includeContext)

        // Append the rendered content to the parent template's buffer
        context.appendToTemplateBuffer(rendered)

        return rendered
    }
}
