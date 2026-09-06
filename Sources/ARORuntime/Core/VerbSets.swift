/// Single source of truth for verb classification used by the interpreter (FeatureSetExecutor)
/// and available as a shared reference for compiler-side decisions (LLVMCodeGenerator).
///
/// Adding a verb here automatically keeps interpreter and documentation in sync.
/// Binary mode generates direct LLVM action calls and does not use needsExecution logic,
/// but this module serves as the canonical vocabulary reference for both modes.
public enum VerbSets {
    /// Testing verbs — fall through to action execution so ThenAction/AssertAction see bindings
    public static let testVerbs: Set<String> = ["then", "assert"]

    /// External service invocation — binds results internally, must always execute.
    /// `parse` lives here (not in extractVerbs) so ParseDispatchAction ALWAYS
    /// runs: dispatch must be qualifier-driven, never statement-shape-driven
    /// (GitLab #521 — the expression fast path used to swallow it).
    public static let requestVerbs: Set<String> = ["call", "invoke", "request", "probe", "fetch", "retrieve", "listen", "parse"]

    /// Mutation verbs — always execute so they can handle rebinding internally
    public static let updateVerbs: Set<String> = ["update", "modify", "change", "set", "configure"]

    /// Creation verbs — execute when specifiers present (typed entities need ID generation)
    public static let createVerbs: Set<String> = ["create", "make", "build", "construct"]

    /// Merge/combine verbs — always execute (transform and bind result)
    public static let mergeVerbs: Set<String> = ["merge", "combine", "join", "concat"]

    /// Compute verbs — execute when specifiers present (operations like +7d, hash, format)
    public static let computeVerbs: Set<String> = ["compute", "calculate", "derive"]

    /// Extract verbs — execute when specifiers present (property extraction like :days, :next)
    /// `parse` deliberately absent: ParseDispatchAction must always run so
    /// dispatch is qualifier-driven, never shape-driven (GitLab #521).
    public static let extractVerbs: Set<String> = ["extract", "get"]

    /// Query/collection verbs — always execute for where-clause and regex processing
    public static let queryVerbs: Set<String> = ["filter", "map", "reduce", "aggregate", "split", "group"]

    /// Response/export verbs — result must not be rebound to the expression value
    public static let responseVerbs: Set<String> = [
        "write", "read", "store", "save", "persist",
        "log", "print", "send", "emit", "notify", "alert", "signal", "broadcast"
    ]

    /// Server/service lifecycle verbs — always execute for side effects
    public static let serverVerbs: Set<String> = [
        "start", "stop", "restart", "keepalive",
        "schedule", "stream", "subscribe",
        "sleep", "delay", "pause"
    ]
}
