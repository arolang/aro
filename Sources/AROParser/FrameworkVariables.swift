// ============================================================
// FrameworkVariables.swift
// AROParser — the `_`-prefixed variables a statement writes for
// its own action to read, and the ones that must not outlive it
// ============================================================
//
// A statement's modifiers do not travel to the action as
// arguments. `with { separator: "-" }` binds `_with_`, `where key
// is X` binds `_where_field_`/`_where_op_`/`_where_value_`, a
// literal object binds `_literal_`, and the action reads them back
// out of the execution context. That works only if the context is
// swept between statements: a modifier nobody cleared is a
// modifier the *next* statement silently inherits.
//
// Both execution modes have to sweep the same names. They did not.
// The interpreter (`FeatureSetExecutor.executeAROStatement`)
// cleared 21; the code generator
// (`LLVMCodeGenerator.generateAROStatement`) emitted
// `aro_variable_unbind` for 14 of them, chosen by hand and grown
// piecemeal as bugs arrived — `_by_var_`, `_by_order_`,
// `_matching_`, `_recursive_` each added by a different MR. The
// seven that never made it across (`_literal_`, `_expression_`,
// `_expression_name_`, `_result_expression_`, `_to_`, `_with_`,
// `_against_`) made `aro run` and `aro build` disagree about the
// same program (GitLab #552):
//
//     Compute the <j1: join> from <one> with { separator: "-" }.
//     Compute the <j2: join> from <two>.        (* no `with` *)
//
// interpreted `cd`, compiled `c-d` — the second join reusing the
// first one's separator.
//
// So the list lives here, once, and both modes iterate it. It sits
// in AROParser rather than ARORuntime because AROCompiler depends
// on AROParser and not on the runtime — the same reasoning that
// put `ComputeQualifierCatalog` here. A test in AROCompilerTests
// asserts the emitted IR unbinds every name in `transientKeys`, so
// adding a modifier to one mode and forgetting the other fails the
// suite instead of shipping two answers for one program.

import Foundation

/// The `_`-prefixed variables the runtime uses to pass a statement's
/// modifiers to the action executing it.
public enum FrameworkVariables {

    /// Every framework variable that belongs to a single statement and must be
    /// cleared before the next one runs.
    ///
    /// Order is the interpreter's clearing order, which is also documentation
    /// order: value sources, then aggregation, query, ordering, and finally the
    /// preposition clauses.
    ///
    /// Both `FeatureSetExecutor.executeAROStatement` (interpreted) and
    /// `LLVMCodeGenerator.generateAROStatement` (compiled) clear exactly this
    /// list at the top of every statement. Add a modifier variable here and
    /// both modes pick it up; add it to only one of them and
    /// `FrameworkVariableParityTests` fails.
    public static let transientKeys: [String] = [
        // Value sources — literal, evaluated expression, sink expression
        "_literal_",
        "_expression_",
        "_expression_name_",
        "_result_expression_",

        // ARO-0018 aggregation
        "_aggregation_type_",
        "_aggregation_field_",

        // ARO-0018 query filters. `_where_tree_` gates the numbered
        // `_where_*_N_` binds, so clearing the tree disarms a stale
        // compound condition without enumerating its parts.
        "_where_field_",
        "_where_op_",
        "_where_value_",
        "_where_tree_",

        // `by` clauses — regex pattern/flags, sort field, sort variable, order
        "_by_pattern_",
        "_by_flags_",
        "_by_field_",
        "_by_var_",
        "_by_order_",

        // Misc modifier clauses
        "_default_value_",
        "_matching_",
        "_recursive_",

        // Preposition clauses: `to` (ranges), `with` (modifier object),
        // `against` (Compare's second operand)
        "_to_",
        "_with_",
        "_against_",
    ]

    /// Framework variables that carry a statement's payload to the runtime but
    /// are written and consumed inside one emitted call, so they need no
    /// per-statement sweep. Listed here only so the compiler can pre-register
    /// their string constants alongside `transientKeys`.
    public static let statementLocalKeys: [String] = [
        "_publish_alias_",
        "_publish_variable_",
        "_require_variable_",
        "_require_source_",
    ]
}
