# Appendix B: Glossary

Terms unique to (or used in a specific way by) the ARO debugger.

---

**Causal call stack.** The chain of *(feature set, triggering event, current statement)* tuples the debugger shows at a pause. Not a function-frame stack; an ordering of cause-and-effect across event-driven hops.

**Checkpoint.** The runtime's call into the debug controller at a statement boundary or hook point (event, error). The unit of "the debugger gets a turn."

**Conditional location breakpoint.** A location breakpoint with an ARO expression predicate. Pauses only when the predicate evaluates truthy against the live context.

**DAP / Debug Adapter Protocol.** Microsoft's wire protocol between editors and debuggers. The `--dap` mode of `aro debug` speaks it.

**DAP frontend.** The Swift actor (`DAPFrontend`) that translates between the controller's `PauseInfo` / `StepMode` shapes and DAP messages on the wire.

**Debug controller.** The `DebugController` Swift actor that holds breakpoint state, decides whether to pause, and hands control to a frontend (CLI or DAP) when it does.

**DebuggerQuit.** A typed Swift error thrown from the controller when the frontend returns `.quit`. Propagates through the executor for a clean unwind instead of `Foundation.exit(0)`.

**Entry pause.** The unconditional first pause of every debug session, before any user statement runs. Provides a starting prompt where you can set breakpoints before execution begins.

**Event breakpoint.** A breakpoint that matches a published event by name. Fires in `EventBus.publish`'s hook, before subscribers fan out (best-effort — see chapter 5.5 caveat).

**Force.** Reading a lazy `AROFuture` to obtain its value. The line that triggers the force is not always the line that *defined* the action that produced the future.

**Force-order stepping.** Advancing the pause cursor by the order the runtime forces futures. Distinct from source-order stepping.

**JSONL event log.** The `.jsonl` file produced by `--record` and consumed by `--replay`. One JSON record per line. Same format the SOLARO time-travel scrubber uses.

**Location breakpoint.** A breakpoint matched on file basename suffix + line number. The simplest case.

**OSO stab.** A Mach-O symbol entry that the macOS linker emits to record "this object file contained DWARF for this address range." `dsymutil` reads OSO entries to build `.dSYM` bundles. Currently missing for ARO-compiled `.o` files (chapter 8.4).

**PauseInfo.** The Sendable value passed from the controller to the frontend when execution pauses. Contains reason, file, line, statement summary, verb, symbol snapshot.

**Predicate evaluator.** The component (`PredicateEvaluator`) that parses a conditional-breakpoint predicate via the full `AROParser` + `ExpressionEvaluator` pipeline. Returns `false` on parse / eval failure — debugger predicates never crash the program.

**Replay.** Re-opening a recorded session without re-executing the program. Scrub forward and backward through pauses; nothing actually runs.

**Sampling stride.** The `--sample N` value. The controller only enters the pause path on every Nth eligible step-mode checkpoint. Breakpoint matches are unaffected.

**Snapshot (symbol).** The list of `(name, type, value-preview)` tuples captured at pause time. Frontends receive snapshots; they do not get the live `ExecutionContext` (except for predicate evaluation, which uses the live context directly).

**Source-order stepping.** The default stepping mode. Advances by the order statements appear in the source file. Distinct from force-order.

**Step into / over / out.** Standard debugger verbs. In ARO they apply to event emits and sub-graph calls (chapter 4.4): step *into* follows the emit, step *over* runs the handlers and lands on the next statement, step *out* runs to the end of the current feature set.

**Statement boundary.** The period at the end of an ARO statement. The unit of stepping. Always paused *before* the named statement executes.

**TaskLocal controller.** `Debug.controller` — the Swift `TaskLocal` field that the runtime reads on every statement boundary. Nil-check fast-path when no debugger is attached.

**Verb breakpoint.** A breakpoint matched on action verb name (`Emit`, `Store`, etc.) regardless of file or line.

**Watch expression.** A label whose current value is printed at every pause. Does not trigger a pause itself.
