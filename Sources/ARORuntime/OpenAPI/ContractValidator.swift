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

        // Check each `paths` operation has a matching feature set (by operationId).
        for (path, pathItem) in spec.paths {
            for (method, operation) in pathItem.allOperations {
                guard let operationId = operation.operationId else {
                    throw ContractValidationError.missingOperationId(
                        path: path,
                        method: method
                    )
                }

                // Skip WebSocket upgrade endpoints (101 Switching Protocols) —
                // those are handled by the runtime, not user-defined feature sets
                let isWebSocketUpgrade = operation.responses.keys.contains("101")
                if !featureSetNames.contains(operationId) && !isWebSocketUpgrade {
                    missingHandlers.append((operationId, path, method))
                }
            }
        }

        // Webhooks (OpenAPI 3.1): handler name is the operationId when present,
        // otherwise the webhook name (GitLab #187) — operationId is not required.
        for (name, item) in spec.webhooks ?? [:] {
            let key = name.hasPrefix("/") ? name : "/\(name)"
            for (method, operation) in item.allOperations {
                let handlerName = operation.operationId ?? name
                let isWebSocketUpgrade = operation.responses.keys.contains("101")
                if !featureSetNames.contains(handlerName) && !isWebSocketUpgrade {
                    missingHandlers.append((handlerName, key, method))
                }
            }
        }

        // Report all missing handlers at once
        if !missingHandlers.isEmpty {
            throw ContractValidationError.missingHandlers(missingHandlers)
        }

        try validateBodyLimits(spec: spec, featureSets: featureSets)
    }

    /// Check `x-aro-max-body` against what the code does with the body
    /// (GitLab #477).
    ///
    /// A declared size that isn't a size is an error, because the alternative
    /// is a limit that silently isn't the one written down. A large limit on a
    /// route that reads its body is a warning, because that many bytes are
    /// held per concurrent request — a fact worth stating where the contract
    /// declares it rather than where the memory runs out.
    public static func validateBodyLimits(
        spec: OpenAPISpec,
        featureSets: [AnalyzedFeatureSet]
    ) throws {
        let summaries = BodyMaterializationAnalyzer.analyze(featureSets.map(\.featureSet))

        for (path, pathItem) in spec.paths {
            for (method, operation) in pathItem.allOperations {
                guard let declared = operation.xAroMaxBody else { continue }
                guard let operationId = operation.operationId else { continue }

                guard let bytes = ByteSize.parse(declared) else {
                    throw ContractValidationError.invalidBodyLimit(
                        operationId: operationId,
                        path: path,
                        method: method.uppercased(),
                        value: declared
                    )
                }

                guard let summary = summaries[operationId], summary.materializes else { continue }
                if bytes > 10_000_000 {
                    let where_ = summary.statement.map { " (\($0))" } ?? ""
                    FileHandle.standardError.write(Data(
                        ("[Contract] \(method.uppercased()) \(path) declares x-aro-max-body: \(declared), "
                         + "and its feature set reads the body\(where_), so that much is held in "
                         + "memory per concurrent request. Stream it, or lower the limit.\n").utf8))
                }
            }
        }
    }

    /// Validate an OpenAPI spec for internal consistency
    /// - Parameter spec: The OpenAPI specification to validate
    /// - Throws: ContractValidationError if validation fails
    public static func validateSpec(_ spec: OpenAPISpec) throws {
        // Check for duplicate operation IDs
        var seenIds: [String: (path: String, method: String)] = [:]

        // `paths` operations require an operationId.
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

        // Webhooks contribute their handler name (operationId or webhook name)
        // to the duplicate check, but do not require an explicit operationId.
        for (name, item) in spec.webhooks ?? [:] {
            let key = name.hasPrefix("/") ? name : "/\(name)"
            for (method, operation) in item.allOperations {
                let handlerName = operation.operationId ?? name
                if let existing = seenIds[handlerName] {
                    throw ContractValidationError.duplicateOperationId(
                        operationId: handlerName,
                        first: (existing.path, existing.method),
                        second: (key, method)
                    )
                }
                seenIds[handlerName] = (key, method)
            }
        }

        // Validate $ref references
        try validateReferences(in: spec)
    }

    /// Validate all $ref references in the spec
    private static func validateReferences(in spec: OpenAPISpec) throws {
        // Collect all schema refs used
        var usedSchemaRefs: Set<String> = []
        var usedParamRefs: Set<String> = []

        // Combine paths and webhooks for reference validation
        var allPathItems = spec.paths
        for (name, item) in spec.webhooks ?? [:] {
            let key = name.hasPrefix("/") ? name : "/\(name)"
            allPathItems[key] = item
        }

        for (_, pathItem) in allPathItems {
            // Collect parameter refs at path level
            for param in pathItem.parameters ?? [] {
                if let ref = param.ref { usedParamRefs.insert(ref) }
            }


            for (_, operation) in pathItem.allOperations {
                // Collect parameter refs at operation level
                for param in operation.parameters ?? [] {
                    if let ref = param.ref { usedParamRefs.insert(ref) }
                }

                // Check request body schema refs
                if let requestBody = operation.requestBody {
                    for (_, mediaType) in requestBody.content {
                        collectSchemaRefs(schemaRef: mediaType.schema, into: &usedSchemaRefs)
                    }
                }

                // Check response schema refs
                for (_, response) in operation.responses {
                    if let content = response.content {
                        for (_, mediaType) in content {
                            collectSchemaRefs(schemaRef: mediaType.schema, into: &usedSchemaRefs)
                        }
                    }
                }
            }
        }

        // Validate schema refs exist in components
        let availableSchemas: Set<String>
        if let schemas = spec.components?.schemas {
            availableSchemas = Set(schemas.keys)
        } else {
            availableSchemas = []
        }

        for ref in usedSchemaRefs {
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

        // Validate parameter refs exist in components
        let availableParams: Set<String>
        if let params = spec.components?.parameters {
            availableParams = Set(params.keys)
        } else {
            availableParams = []
        }

        for ref in usedParamRefs {
            let parts = ref.split(separator: "/")
            if parts.count == 4,
               parts[0] == "#",
               parts[1] == "components",
               parts[2] == "parameters" {
                let paramName = String(parts[3])
                if !availableParams.contains(paramName) {
                    throw ContractValidationError.invalidParameterReference(
                        ref: ref,
                        availableParameters: Array(availableParams)
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

    /// `x-aro-max-body` is present but not a size (GitLab #477)
    case invalidBodyLimit(operationId: String, path: String, method: String, value: String)

    /// Invalid schema $ref reference
    case invalidSchemaReference(ref: String, availableSchemas: [String])

    /// Invalid parameter $ref reference
    case invalidParameterReference(ref: String, availableParameters: [String])

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

        case .invalidBodyLimit(let operationId, let path, let method, let value):
            return "\(method) \(path) (\(operationId)) declares x-aro-max-body: \(value), "
                + "which is not a size. Write it as 1MB, 512KB, or a byte count."

        case .invalidSchemaReference(let ref, let availableSchemas):
            var message = "Invalid schema reference: \(ref)"
            if !availableSchemas.isEmpty {
                message += "\nAvailable schemas: \(availableSchemas.joined(separator: ", "))"
            }
            return message

        case .invalidParameterReference(let ref, let availableParameters):
            var message = "Invalid parameter reference: \(ref)"
            if !availableParameters.isEmpty {
                message += "\nAvailable parameters: \(availableParameters.joined(separator: ", "))"
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
