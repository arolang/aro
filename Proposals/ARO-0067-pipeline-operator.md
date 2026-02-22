# ARO-0067: Pipeline Operator

* Proposal: ARO-0067
* Author: ARO Language Team
* Status: **Implemented**
* Related Issues: GitLab #105

## Abstract

Add pipeline operator `|>` for chaining data transformations, enabling clearer data flow without intermediate variables.

## Problem

Current approach requires multiple statements with intermediate variables:

```aro
Extract the <raw-data> from the <request: body>.
Transform the <cleaned-data> from the <raw-data> with "trim".
Transform the <parsed-data> from the <cleaned-data> with "parse-json".
Validate the <valid-data> from the <parsed-data>.
Store the <valid-data> in the <repository>.
```

## Solution

Add `|>` pipeline operator for left-to-right data flow:

```aro
Extract <data> from <request: body>
  |> Transform with "trim"
  |> Transform with "parse-json"
  |> Validate
  |> Store in <repository>.
```

## Syntax

### Lexer Token

Add `TokenKind.pipe` for `|>`:

```swift
case "|":
    if peek() == ">" {
        advance()
        addToken(.pipe, start: startLocation)  // |>
    } else {
        throw LexerError.unexpectedCharacter("|", at: startLocation)
    }
```

### Parser

Pipeline expression chains actions:

```swift
// Parse initial statement
var statement = try parseAROStatement()

// Check for pipeline continuation
while peek().kind == .pipe {
    advance()  // consume |>

    // Parse next action (infers object from previous result)
    let nextAction = try parseChainedAction()
    statement = createPipelineStatement(previous: statement, next: nextAction)
}
```

### AST

```swift
public struct PipelineStatement: Statement {
    public let stages: [AROStatement]
    public let span: SourceSpan
}
```

## Examples

### API Request Processing

```aro
(Process Request: API Handler) {
    Extract <data> from <request: body>
      |> Validate
      |> Transform with "normalize"
      |> Store in <repository>
      |> Log to <audit-log>.

    Return an <OK: status> with <data>.
}
```

### Data Transformation Pipeline

```aro
(Clean User Data: Data Pipeline) {
    Extract <users> from <raw-file>
      |> Filter where status = "active"
      |> Transform with "trim-whitespace"
      |> Transform with "lowercase-email"
      |> Sort by <created-date>
      |> Store in <user-repository>.

    Return an <OK: status>.
}
```

### Object Implicit in Pipeline

Each stage receives the previous stage's result as implicit input:

```aro
(* Explicit *)
Extract the <data> from <source>.
Transform the <cleaned> from <data> with "trim".
Validate the <valid> from <cleaned>.

(* Pipeline - 'data' is implicit *)
Extract <data> from <source>
  |> Transform with "trim"     (* operates on <data> *)
  |> Validate.                  (* operates on transformed result *)
```

## Implementation

### Lexer Change

```swift
case "|":
    if peek() == ">" {
        _ = advance()
        addToken(.pipe, start: startLocation)
    } else {
        throw LexerError.unexpectedCharacter("|", at: startLocation)
    }
```

### Parser Change

```swift
private func parseStatement() throws -> Statement {
    let stmt = try parseAROStatement()

    // Check for pipeline
    if peek().kind == .pipe {
        return try parsePipelineStatement(initial: stmt)
    }

    return stmt
}

private func parsePipelineStatement(initial: AROStatement) throws -> PipelineStatement {
    var stages = [initial]

    while peek().kind == .pipe {
        advance()  // consume |>

        // Parse action with implicit object
        let nextStage = try parseChainedStatement(previousResult: stages.last!.result)
        stages.append(nextStage)
    }

    return PipelineStatement(stages: stages, span: ...)
}
```

### Execution

Execute stages sequentially, passing result between stages:

```swift
func execute(_ pipeline: PipelineStatement, context: ExecutionContext) async throws {
    var currentValue: any Sendable = ()

    for stage in pipeline.stages {
        // Bind previous result to current object if needed
        if stage != pipeline.stages.first {
            context.bind(stage.object.noun.base, value: currentValue)
        }

        currentValue = try await executeAROStatement(stage, context: context)
    }
}
```

## Benefits

1. **Readability**: Clear left-to-right or top-to-bottom flow
2. **Conciseness**: No intermediate variable names needed
3. **Composability**: Easy to add/remove transformation steps
4. **Debugging**: Each step can be inspected independently
5. **Familiar**: Like F#, Elixir, Unix pipes

## Compatibility

Fully backward compatible - existing code continues to work. Pipeline is opt-in syntax sugar.

Fixes GitLab #105
