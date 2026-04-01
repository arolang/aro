# Chapter 5: Command

*"Speak to the REPL itself with commands."*

---

## The Colon Prefix

Commands start with `:`. They control the REPL, not ARO:

```
aro> :help      # Talk to the REPL
aro> <Set>...   # Talk to ARO
```

Two languages. One prompt. The colon is the switch.

## Essential Commands

### Inspection

```
aro> :vars              # List all variables
aro> :vars user         # Inspect one variable
aro> :type user         # Show variable type
```

### Session Control

```
aro> :clear             # Wipe all variables
aro> :history           # Show command history
aro> :history 10        # Last 10 commands
```

### Feature Sets

```
aro> :fs                # List feature sets
aro> :invoke Name       # Run a feature set
```

### Export

```
aro> :export            # Print as .aro code
aro> :export file.aro   # Save to file
```

### Exit

```
aro> :quit              # Leave the REPL
```

## History Navigation

The REPL remembers everything you've typed. Navigate with arrow keys:

| Key | Action |
|-----|--------|
| `Up` | Previous command |
| `Down` | Next command |
| `Ctrl+R` | Search history |

Find a command, press Enter, it runs again.

## Tab Completion

Press `Tab` for intelligent completion:

```
aro> <Com[TAB]
Compute  Compare  <Connect>

aro> :h[TAB]
:help     :history
```

The REPL knows ARO. It knows your variables. It helps.

## The History Command

See what you've done:

```
aro> :history 5
1. [ok]  Set the <x> to 10.           2ms
2. [ok]  Set the <y> to 20.           1ms
3. [ok]  Compute the <sum> from...    3ms
4. [err] Get the <missing> from...   --
5. [ok]  Log "test" to <console>.    1ms
```

Status, statement, timing. A record of your conversation.

## Aliases

Most commands have short forms:

| Full | Short |
|------|-------|
| `:help` | `:h` or `:?` |
| `:vars` | `:v` |
| `:clear` | `:c` |
| `:history` | `:hist` |
| `:export` | `:e` |
| `:invoke` | `:i` |
| `:quit` | `:q` |

Less typing. Same power.

---

**Next: Chapter 6 — Extend**
