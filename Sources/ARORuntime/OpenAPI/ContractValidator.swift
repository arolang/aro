// ============================================================
// ContractValidator.swift
// ARO Runtime - OpenAPI Contract Validation
// ============================================================

import Foundation
import AROParser

/// Validates OpenAPI contracts against ARO feature sets
public struct ContractValidator {
    /// Validate that all OpenAPI operations have matching ARO feature sets
    /// - Parameters:
    ///   - spec: The OpenAPI specification
    ///   - featureSets: The analyzed feature sets from the ARO application
    /// - Throws: ContractValidationError if validation fails
    public static func validate(
        spec: OpenAPISpec,
        featureSets: [AnalyzedFeatureSet]
    ) throws {
        // Get all feature set names
        let featureSetNames = Set(featureSets.map { $0.featureSet.name })

        // Track missing handlers
        var missingHandlers: [(operationId: String, path: String, method: String)] = []

        // Check each operation has a matching feature set
        for (path, pathItem) in spec.paths {
            for (method, operation) in pathItem.allOperations {
                guard let operationId = operation.operationId else {
                    throw ContractValidationError.missingOperationId(
                        path: path,
                        method: method
                    )
                }

                if !featureSetNames.contains(operationId) {
                    missingHandlers.append((operationId, path, method))
                }
            }
        }

        // Report all missing handlers at once
        if !missingHandlers.isEmpty {
            throw ContractValidationError.missingHandlers(missingHandlers)
        }
    }

    /// Validate an OpenAPI spec for internal consistency
    /// - Parameter spec: The OpenAPI specification to validate
    /// - Throws: ContractValidationError if validation fails
    public static func validateSpec(_ spec: OpenAPISpec) throws {
        // Check for duplicate operation IDs
        var seenIds: [String: (path: String, method: String)] = [:]

        for (path, pathItem) in spec.paths {
            for (method, operation) in pathItem.allOperations {
                guard let operationId = operation.operationId else {
                    throw ContractValidationError.missingOperationId(
                        path: path,
                        method: method
                    )
                }

                if let existing = seenIds[operationId] {
                    throw ContractValidationError.duplicateOperationId(
                        operationId: operationId,
                        first: (existing.path, existing.method),
                        second: (path, method)
                    )
                }

                seenIds[operationId] = (path, method)
            }
        }

        // Validate $ref references
        try validateReferences(in: spec)
    }

    /// Validate all $ref references in the spec
    private static func validateReferences(in spec: OpenAPISpec) throws {
        // Collect all schema refs used
        var usedRefs: Set<String> = []

        for (_, pathItem) in spec.paths {
            for (_, operation) in pathItem.allOperations {
                // Check request body schema refs
                if let requestBody = operation.requestBody {
                    for (_, mediaType) in requestBody.content {
                        collectSchemaRefs(schemaRef: mediaType.schema, into: &usedRefs)
                    }
                }

                // Check response schema refs
                for (_, response) in operation.responses {
                    if let content = response.content {
                        for (_, mediaType) in content {
                            collectSchemaRefs(schemaRef: mediaType.schema, into: &usedRefs)
                        }
                    }
                }
            }
        }

        // Validate all refs exist in components
        let availableSchemas: Set<String>
        if let schemas = spec.components?.schemas {
            availableSchemas = Set(schemas.keys)
        } else {
            availableSchemas = []
        }

        for ref in usedRefs {
            // Parse ref like "#/components/schemas/User"
            let parts = ref.split(separator: "/")
            if parts.count == 4,
               parts[0] == "#",
               parts[1] == "components",
               parts[2] == "schemas" {
                let schemaName = String(parts[3])
                if !availableSchemas.contains(schemaName) {
                    throw ContractValidationError.invalidSchemaReference(
                        ref: ref,
                        availableSchemas: Array(availableSchemas)
                    )
                }
            }
        }
    }

    /// Recursively collect schema refs from a SchemaRef
    private static func collectSchemaRefs(schemaRef: SchemaRef?, into refs: inout Set<String>) {
        guard let schemaRef = schemaRef else { return }
        collectSchemaRefsFromSchema(schema: schemaRef.value, into: &refs)
    }

    /// Recursively collect schema refs from a Schema
    private static func collectSchemaRefsFromSchema(schema: Schema, into refs: inout Set<String>) {
        if let ref = schema.ref {
            refs.insert(ref)
        }

        // Check nested schemas
        if let properties = schema.properties {
            for (_, propSchemaRef) in properties {
                collectSchemaRefs(schemaRef: propSchemaRef, into: &refs)
            }
        }

        if let items = schema.items {
            collectSchemaRefs(schemaRef: items, into: &refs)
        }

        if let allOf = schema.allOf {
            for subSchemaRef in allOf {
                collectSchemaRefs(schemaRef: subSchemaRef, into: &refs)
            }
        }

        if let oneOf = schema.oneOf {
            for subSchemaRef in oneOf {
                collectSchemaRefs(schemaRef: subSchemaRef, into: &refs)
            }
        }

        if let anyOf = schema.anyOf {
            for subSchemaRef in anyOf {
                collectSchemaRefs(schemaRef: subSchemaRef, into: &refs)
            }
        }
    }
}

// MARK: - Errors

/// Errors that occur during contract validation
public enum ContractValidationError: Error, Sendable {
    /// An operation is missing an operationId
    case missingOperationId(path: String, method: String)

    /// One or more operationIds don't have matching feature set handlers
    case missingHandlers([(operationId: String, path: String, method: String)])

    /// Duplicate operationId found
    case duplicateOperationId(
        operationId: String,
        first: (path: String, method: String),
        second: (path: String, method: String)
    )

    /// Invalid $ref reference
    case invalidSchemaReference(ref: String, availableSchemas: [String])

    /// No OpenAPI contract found
    case noContract(directory: String)
}

extension ContractValidationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingOperationId(let path, let method):
            return "Missing operationId for \(method) \(path). All operations must have an operationId."

        case .missingHandlers(let handlers):
            var message = "Missing ARO feature set handlers for the following operations:\n"
            for (operationId, path, method) in handlers {
                message += "  - \(method) \(path) requires feature set named '\(operationId)'\n"
            }
            message += "\nCreate feature sets with names matching the operationIds in your OpenAPI contract."
            return message

        case .duplicateOperationId(let operationId, let first, let second):
            return "Duplicate operationId '\(operationId)' found:\n  - \(first.1) \(first.0)\n  - \(second.1) \(second.0)"

        case .invalidSchemaReference(let ref, let availableSchemas):
            var message = "Invalid schema reference: \(ref)"
            if !availableSchemas.isEmpty {
                message += "\nAvailable schemas: \(availableSchemas.joined(separator: ", "))"
            }
            return message

        case .noContract(let directory):
            return "No OpenAPI contract found in \(directory). Create an openapi.yaml file to enable HTTP routing."
        }
    }
}

// MARK: - Validation Result

/// Result of contract validation
public struct ContractValidationResult: Sendable {
    /// Whether validation passed
    public let isValid: Bool

    /// Warnings (non-fatal issues)
    public let warnings: [String]

    /// Matched operations
    public let matchedOperations: [String]

    /// Create a successful result
    public static func success(matchedOperations: [String], warnings: [String] = []) -> ContractValidationResult {
        ContractValidationResult(
            isValid: true,
            warnings: warnings,
            matchedOperations: matchedOperations
        )
    }
}
