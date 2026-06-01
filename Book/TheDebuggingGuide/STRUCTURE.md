# ARO Debugging Guide — Structure

Each chapter file matches its file name and a section heading inside the chapter.

---

## Part I — Foundations

1. **Why ARO Debugging Is Different** — what changes when the language has only one shape for a statement
2. **Getting Set Up** — installing, pointing the binary at a project, verifying `aro debug --help`
3. **Your First Session** — stepping `Examples/HelloWorld` to a clean exit

## Part II — Driving the Debugger

4. **The Statement-Boundary Model** — what *pause* actually means, lazy futures, and why one verb is one step
5. **Breakpoints — All Five Flavors** — location, verb, conditional, event, error-any
6. **Watch Expressions** — typed predicates that survive every pause

## Part III — Editor Integration

7. **The DAP Bridge** — VS Code, IntelliJ, and Neovim attach paths
8. **What lldb Can and Cannot See** — interpreter vs compiled-binary debugging, the DWARF story

## Part IV — Time and Distance

9. **Recording and Replay** — `--record`, the JSONL event log, scrubbing without re-execution
10. **Production Attach** — `--sample`, the TCP DAP listener, what to do (and not) on a live server

## Appendices

- **Appendix A — Command Reference** — every TUI command, every flag, every breakpoint case
- **Appendix B — Glossary** — the small set of terms unique to the ARO debugger

---

Cross-references: this book builds on knowledge from `TheLanguageGuide` (Action-Result-Object basics, feature sets, the event bus) and pairs with the SOLARO ADRs in issue #228 if you also use the canvas.
