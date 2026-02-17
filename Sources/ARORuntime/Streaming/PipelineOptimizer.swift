// PipelineOptimizer.swift
// ARO Streaming Execution Engine
//
// Optimizes streaming pipelines before execution.
// Inspired by Apache Spark's Catalyst optimizer.

import Foundation
import AROParser

/// Optimizes streaming pipelines for better performance.
///
/// The optimizer applies several transformations:
/// - **Predicate Pushdown**: Move filters closer to data sources
/// - **Projection Pruning**: Only read needed columns
/// - **Pipeline Fusion**: Combine adjacent operations
///
/// Example:
/// ```
/// Before: Read -> Transform -> Filter
/// After:  Read -> Filter -> Transform  (fewer rows to transform)
/// ```
public actor PipelineOptimizer {

    /// Optimization statistics
    public struct OptimizationStats: Sendable {
        public var predicatesPushed: Int = 0
        public var projectionsPruned: Int = 0
        public var operationsFused: Int = 0
    }

    private var stats = OptimizationStats()

    public init() {}

    /// Optimize a feature set's statements
    public func optimize(_ featureSet: AnalyzedFeatureSet) -> OptimizedPipeline {
        var pipeline = OptimizedPipeline(featureSet: featureSet)

        // Apply optimizations
        applyPredicatePushdown(&pipeline)
        applyProjectionPruning(&pipeline)
        applyOperationFusion(&pipeline)

        pipeline.stats = stats
        return pipeline
    }

    /// Push filters as close to data sources as possible
    ///
    /// If we have: Read -> Transform -> Filter
    /// And the filter doesn't depend on the transform output,
    /// we can reorder to: Read -> Filter -> Transform
    /// This reduces the number of rows processed by Transform.
    private func applyPredicatePushdown(_ pipeline: inout OptimizedPipeline) {
        let statements = pipeline.featureSet.featureSet.statements

        // Build dependency map: which variables does each statement use?
        var usedVariables: [Int: Set<String>] = [:]
        var producedVariables: [Int: String] = [:]

        for (index, stmt) in statements.enumerated() {
            if let aroStmt = stmt as? AROStatement {
                producedVariables[index] = aroStmt.result.base
                usedVariables[index] = extractUsedVariables(aroStmt)
            }
        }

        // Find Filter statements that can be pushed earlier
        for (index, stmt) in statements.enumerated() {
            if let aroStmt = stmt as? AROStatement,
               aroStmt.action.verb.lowercased() == "filter" {

                let filterUses = usedVariables[index] ?? []

                // Check if we can push this filter before the previous statement
                if index > 0,
                   let prevOutput = producedVariables[index - 1],
                   !filterUses.contains(prevOutput) {
                    // Filter doesn't depend on previous output - can push
                    pipeline.optimizations.append(.predicatePushdown(
                        filterIndex: index,
                        newIndex: index - 1
                    ))
                    stats.predicatesPushed += 1
                }
            }
        }
    }

    /// Prune projections to only read needed columns
    ///
    /// Traces which fields are actually accessed throughout the pipeline
    /// and tells data sources to only parse those columns.
    private func applyProjectionPruning(_ pipeline: inout OptimizedPipeline) {
        let statements = pipeline.featureSet.featureSet.statements

        // Collect all accessed field names
        var accessedFields: Set<String> = []

        for stmt in statements {
            if let aroStmt = stmt as? AROStatement {
                accessedFields.formUnion(extractAccessedFields(aroStmt))
            }
        }

        if !accessedFields.isEmpty {
            pipeline.projectedFields = accessedFields
            stats.projectionsPruned = accessedFields.count
        }
    }

    /// Fuse adjacent operations for single-pass execution
    ///
    /// Multiple filters on same source -> single filter with AND
    /// Multiple maps -> single map with composition
    private func applyOperationFusion(_ pipeline: inout OptimizedPipeline) {
        let statements = pipeline.featureSet.featureSet.statements

        var lastFilterSource: String?
        var consecutiveFilters: [(Int, AROStatement)] = []

        for (index, stmt) in statements.enumerated() {
            if let aroStmt = stmt as? AROStatement,
               aroStmt.action.verb.lowercased() == "filter" {

                let source = aroStmt.object.noun.base

                if lastFilterSource == source {
                    consecutiveFilters.append((index, aroStmt))
                } else {
                    // Flush any pending filter fusion
                    if consecutiveFilters.count > 1 {
                        pipeline.optimizations.append(.filterFusion(
                            indices: consecutiveFilters.map { $0.0 }
                        ))
                        stats.operationsFused += consecutiveFilters.count - 1
                    }
                    consecutiveFilters = [(index, aroStmt)]
                    lastFilterSource = source
                }
            } else {
                // Non-filter breaks the chain
                if consecutiveFilters.count > 1 {
                    pipeline.optimizations.append(.filterFusion(
                        indices: consecutiveFilters.map { $0.0 }
                    ))
                    stats.operationsFused += consecutiveFilters.count - 1
                }
                consecutiveFilters = []
                lastFilterSource = nil
            }
        }

        // Handle trailing filters
        if consecutiveFilters.count > 1 {
            pipeline.optimizations.append(.filterFusion(
                indices: consecutiveFilters.map { $0.0 }
            ))
            stats.operationsFused += consecutiveFilters.count - 1
        }
    }

    /// Extract variable names used by a statement
    private func extractUsedVariables(_ stmt: AROStatement) -> Set<String> {
        var used: Set<String> = []

        // Object noun base is typically the input
        used.insert(stmt.object.noun.base)

        // Check for field references in where clause
        if let whereClause = stmt.queryModifiers.whereClause {
            used.insert(whereClause.field)
            // If value is a variable reference, add it
            if let varRef = whereClause.value as? VariableRefExpression {
                used.insert(varRef.noun.base)
            }
        }

        return used
    }

    /// Extract field names accessed from dictionaries
    private func extractAccessedFields(_ stmt: AROStatement) -> Set<String> {
        var fields: Set<String> = []

        // Where clause field
        if let whereClause = stmt.queryModifiers.whereClause {
            fields.insert(whereClause.field)
        }

        // Result specifiers often reference fields
        for spec in stmt.result.specifiers {
            fields.insert(spec)
        }

        return fields
    }

    /// Get current optimization stats
    public func getStats() -> OptimizationStats {
        stats
    }
}

// MARK: - Optimized Pipeline

/// A pipeline with optimization information
public struct OptimizedPipeline: Sendable {
    /// The original feature set
    public let featureSet: AnalyzedFeatureSet

    /// Optimizations to apply
    public var optimizations: [PipelineOptimization] = []

    /// Fields to project (only these columns need to be read)
    public var projectedFields: Set<String>?

    /// Statistics about optimizations applied
    public var stats: PipelineOptimizer.OptimizationStats?

    public init(featureSet: AnalyzedFeatureSet) {
        self.featureSet = featureSet
    }

    /// Check if any optimizations were applied
    public var isOptimized: Bool {
        !optimizations.isEmpty || projectedFields != nil
    }
}

/// Types of pipeline optimizations
public enum PipelineOptimization: Sendable {
    /// Push a filter earlier in the pipeline
    case predicatePushdown(filterIndex: Int, newIndex: Int)

    /// Fuse multiple filters into one
    case filterFusion(indices: [Int])

    /// Fuse multiple maps into one
    case mapFusion(indices: [Int])

    /// Only read specific columns from source
    case projectionPushdown(fields: Set<String>)
}
