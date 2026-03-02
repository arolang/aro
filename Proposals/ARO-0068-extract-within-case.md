# ARO-0068: Extract-Within-Case Syntax

* Proposal: ARO-0068
* Author: ARO Language Team
* Status: **Implemented**
* Related Issues: GitLab #104

## Abstract

ARO's match statement supports extracting and transforming data within case blocks, providing a simpler alternative to full destructuring patterns.

## Problem

Pattern matching with destructuring (as seen in Rust, Swift, etc.) can be complex to implement and reason about. Users need a way to extract data based on match conditions without full destructuring syntax.

## Solution

ARO already supports executing arbitrary statements within match case blocks, including Extract, Compute, Transform, and other data operations. This provides destructuring-like capabilities with familiar ARO syntax.

## Syntax

```aro
match <value> {
    case <pattern> {
        (* Any ARO statements can execute here *)
        Extract the <field> from the <value: property>.
        Compute the <result> from the <field>.
        (* ... more operations *)
    }
    otherwise {
        (* Fallback case *)
    }
}
```

## Example

```aro
(Application-Start: Extract Test) {
    Extract the <response> from {
        "status": 200,
        "body": {"message": "Success", "data": [1, 2, 3]}
    }.

    Extract the <status> from the <response: status>.

    match <status> {
        case 200 {
            (* Extract data within case block *)
            Extract the <body> from the <response: body>.
            Extract the <message> from the <body: message>.
            Log "Success:" to the <console>.
            Log <message> to the <console>.
        }
        case 404 {
            Log "Not found" to the <console>.
        }
        otherwise {
            Log "Other status" to the <console>.
        }
    }

    Return an <OK: status> for the <test>.
}
```

Output:
```
[Application-Start] Status value: 200
[Application-Start] Success: Success
```

## Benefits

1. **Simplicity**: Uses existing ARO syntax (Extract, Compute, etc.)
2. **Flexibility**: Any statement can execute in case blocks
3. **Readability**: Explicit operations are easier to understand than patterns
4. **No New Syntax**: Leverages ARO's existing capabilities
5. **Progressive Disclosure**: Users learn one concept at a time

## Comparison to Full Destructuring

### Full Destructuring (NOT in ARO):
```aro
match <user> {
    case { name: <name>, age: <age> } when <age> >= 18 {
        Log "Adult: \(<name>)" to <console>.
    }
}
```

### ARO Extract-Within-Case (IMPLEMENTED):
```aro
match <user: age> >= 18 {
    case true {
        Extract the <name> from the <user: name>.
        Extract the <age> from the <user: age>.
        Log "Adult:" to <console>.
        Log <name> to <console>.
    }
}
```

## Advantages Over Destructuring

1. **Simpler Parser**: No pattern syntax to parse
2. **Simpler Semantics**: No pattern matching engine needed
3. **Explicit Data Flow**: Each Extract clearly shows what's being extracted
4. **Familiar**: Uses same syntax as outside match blocks
5. **Composable**: Can combine with other actions (Compute, Transform, etc.)

## Design Decision

For GitLab #104, the simpler "extract-within-case" approach was chosen over full destructuring patterns because:

- It's already implemented and working
- It aligns with ARO's philosophy of explicit, readable code
- It requires no new syntax or semantics
- It's more flexible (any statement can execute)

## Implementation

No implementation needed - this capability already exists in ARO's match statement implementation. Case blocks are just arrays of statements that execute when the pattern matches.

See `Examples/ExtractInCase` for a working example.

Fixes GitLab #104
