// ============================================================
// IncludeAction.swift
// ARO Runtime - Include Action for Templates (ARO-0050)
// ============================================================

import Foundation
import AROParser

/// Includes another template within a template (ARO-0050)
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
    /// `from` only — deliberately not `with`.
    ///
    /// `with` as the *primary* preposition cannot work: the object is then an
    /// expression, and `FeatureSetExecutor`'s `!needsExecution` fast path binds
    /// that expression's value to the result and never dispatches the action.
    /// So `Include the <template: card.tpl> with { user: <u> }.` — the spelling
    /// ARO-0050 §10 used to specify — parsed, bound a variable, and rendered
    /// nothing at all, with no diagnostic (GitLab #563).
    ///
    /// Declaring only `from` makes `CodeQualityValidator.validatePrepositions`
    /// report it at check time, with a hint naming the spelling that works.
    /// A **trailing** `with` clause is unaffected and still passes overrides:
    /// `Include the <c> from the <template: card.tpl> with { label: "Go" }.`
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    /// Rebuild a template path from a qualified noun's specifiers.
    ///
    /// Specifiers are split on `:` and `.`, so `header.tpl` arrives as
    /// `["header", "tpl"]` and has to be rejoined. A single specifier that
    /// names a bound variable is resolved instead, so
    /// `<template: chosen-partial>` works.
    static func path(fromSpecifiers specifiers: [String], context: ExecutionContext) -> String {
        if specifiers.count == 1, let resolved: String = context.resolve(specifiers[0]) {
            return resolved
        }
        return specifiers.joined(separator: ".")
    }

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get template path from object base or specifiers
        let templatePath: String

        // ARO-0050 §10 used to write the `with` form with the template in the
        // *result* slot:
        //
        //     {{ Include the <template: user-card.tpl> with { user: <u> }. }}
        //
        // That parses — `with` satisfies the preposition — but the template is
        // then in the result slot, where ARO binds a variable. Two includes in
        // one template would both bind `template`, which immutability forbids,
        // so the spelling cannot work as written and the proposal has been
        // amended to the `from` form. What it used to do was worse than
        // failing: the path was read from the object, which is the `with`
        // literal, so the include rendered to the empty string with no
        // diagnostic at all (GitLab #563). Say what to write instead.
        if result.base.lowercased() == "template", !result.specifiers.isEmpty {
            let path = Self.path(fromSpecifiers: result.specifiers, context: context)
            throw ActionError.invalidInput(
                "Include needs a result binding, and the template goes after `from`: "
                + "write `Include the <part> from the <template: \(path)>"
                + (object.preposition == .with ? " with …" : "") + ".`",
                received: "Include the <template: \(path)> \(object.preposition.rawValue) …"
            )
        } else if object.base.lowercased() == "template" {
            guard !object.specifiers.isEmpty else {
                throw ActionError.missingRequiredField(field: "a template path", action: "Include")
            }
            templatePath = Self.path(
                fromSpecifiers: object.specifiers, context: context)
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
            throw ActionError.missingService("RuntimeContext (template include requires a full runtime context)")
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
