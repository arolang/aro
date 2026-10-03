"""Explain stratum: a question about ARO, answered in prose (GitLab #785).

Graded by rubric — every phrase in `must_include` has to appear and none in
`must_not_include` — the same crude, reproducible judge `functional_eval`
already applies, for the same reason: it needs no judge model and the failure
it catches is the *confident wrong answer*, which a `must_not_include` naming
the plausible-but-wrong alternative catches exactly.

Why these questions and not the corpus's: `Train/Material/` is 191 captures of
"How to X?" with a canonical answer each, and `Train/eval_prompts.json`'s
`explain` category is eleven more of the same. Asking "How to throw an error in
ARO?" again measures recall of a file in the training set. So every question
here is a *why*, a *which of two*, or a *what happens when* — the shapes where
a model that has memorised a snippet has nothing to recall — and each one is
pointed at something the runtime actually does, verified against the binary
this benchmark was frozen on.

Each row: (id, domain, prompt, reference, must_include, must_not_include).
"""

ROWS = [
    ('explain-001', 'throw',
     'Which preposition does the Throw action accept, and what does `aro '
     'check` do when you hand it the wrong one?',
     'Throw accepts only `for`. `Throw a <BadRequest: status> for "under '
     'age".` is the shape. A preposition the action does not accept is '
     'reported by `aro check` as a *warning*, not an error, so the exit code '
     'stays 0 and the program is still broken: it fails at run time with '
     '"Invalid preposition". That is the trap — a green check is not a '
     'promise that every statement will run.',
     ['for', 'warning'],
     ['with is the only preposition',
      'accepts both for and with']),

    ('explain-002', 'throw',
     'If every feature set is supposed to contain only the happy case, what '
     'is Throw for?',
     'The happy-case rule is about not writing error *plumbing* — no '
     'try/catch, no error returns, no checking whether the last statement '
     'worked. The runtime reconstructs a failed statement with its values. '
     'Throw is for the cases where the business rule itself is a refusal: a '
     'request that is not allowed, a value outside its domain. It states the '
     'refusal as the outcome of the feature set rather than handling somebody '
     "else's failure.",
     ['Throw', 'happy'],
     ['wrap it in a try',
      'ARO has no Throw']),

    ('explain-003', 'throw',
     'What is the difference between returning a NotFound status and throwing '
     'one?',
     'Return ends the feature set with that status as its successful outcome '
     '— the handler decided the answer is "no such thing" and said so. Throw '
     'ends it as a failure: the runtime takes over, reconstructs the statement '
     'that threw with its values, and nothing after it runs. Both can produce '
     'a 404 to an HTTP caller; only Throw abandons the rest of the feature '
     'set.',
     ['Return', 'Throw'],
     ['they are identical',
      'there is no difference between them']),

    ('explain-004', 'throw',
     'Can a Throw statement carry a `when` guard, and what happens to the '
     'statements after it when the guard is false?',
     'Yes — `Throw a <BadRequest: status> for "under age" when <age> < 18.` '
     'is valid. When the guard is false the Throw simply does not run and '
     'execution carries on with the next statement, which is how a guard '
     'clause at the top of a feature set is written in ARO.',
     ['when', 'guard'],
     ['Throw cannot carry',
      'guards are not allowed on Throw']),

    ('explain-005', 'publish',
     'How far does a published variable reach — the file, the application, or '
     'something else?',
     'Neither. `Publish as <alias> <value>.` makes the name visible to other '
     'feature sets in the same **business activity**. A feature set whose '
     'activity is "Reporting" can `Require the <alias> from the <Reporting>.`; '
     'one whose activity is "Ready Handler" cannot, and the runtime says so '
     '("it was published in \'Reporting\'"). Files are irrelevant — ARO has no '
     'imports within an application.',
     ['business activity'],
     ['visible across the whole application',
      'globally visible to every feature set',
      'only within the same file']),

    ('explain-006', 'publish',
     'What is left bound when a guarded Publish statement has a false guard?',
     'Nothing. `Publish as <fast-tuning> <tuning> when <mode> == "fast".` '
     'with a mode of "slow" leaves the name `fast-tuning` unpublished — not '
     'published-as-empty, not published-as-false. A reader has to cope with '
     'the name not existing, which is the point of guarding a publish at all.',
     ['unpublished'],
     ['published as an empty string',
      'the alias is bound to false',
      'the alias is bound to null']),

    ('explain-007', 'publish',
     'When would I reach for Publish instead of Emit, given both make '
     'something available outside the feature set?',
     'Publish shares a *value* under a name, synchronously, within the '
     'business activity; whoever reads it reads it when they run. Emit '
     'announces that something *happened*, and the event bus routes it to '
     'every feature set whose business activity is "<EventName> Handler", '
     'which run as their own units of work. Publish is a binding; Emit is a '
     'notification.',
     ['Publish', 'Emit', 'Handler'],
     ['they are interchangeable',
      'they do exactly the same thing']),

    ('explain-008', 'publish',
     'A feature set has `Require the <settings> from the <ConfigLoader>.` and '
     'nothing publishes `settings`. What does `aro check` say, and is that an '
     'error?',
     'It warns that the external dependency is not published by any feature '
     'set. That is a warning rather than an error, and it is the one case '
     'where the warning is the whole point of the statement: naming the '
     'dependency is how you ask the checker to tell you nobody satisfies it. '
     'The source name is a single identifier, so a multi-word feature set '
     'cannot be named there.',
     ['warning', 'not published'],
     ['that is a hard error',
      'aro check refuses to check',
      'aro check exits 1']),

    ('explain-009', 'conditionals',
     'ARO has no if/else. How do I express "do A otherwise do B"?',
     'Two guarded statements with complementary conditions, or a `match`. '
     '`Log "ferry cancelled" to the <console> when <tide> < 1.5.` followed by '
     '`Log "ferry sails" to the <console> when <tide> >= 1.5.` is the pair. '
     '`match <state> { case … { } otherwise { } }` is the right shape when '
     'you are branching on one value with several outcomes; the first '
     'matching case wins.',
     ['when', 'match'],
     ['if <condition> then',
      'use an else block']),

    ('explain-010', 'conditionals',
     'Why does `when <name> starts with "api"` exist when `matches` can do '
     'the same job with a regex?',
     'Because the affix operators are literal, and that is the point of '
     'having them. `matches "^a.c"` also accepts `axc`, because the pattern is '
     'a regex and `.` is a metacharacter. `starts with` and `ends with` '
     'compare the text as written, with no pattern language in between, which '
     'is what you almost always meant.',
     ['literal'],
     ['it is identical to matches',
      'there is no reason for them']),

    ('explain-011', 'conditionals',
     'Are `starts` and `ends` reserved words I have to avoid when naming '
     'variables?',
     'No. They become operators only when `with` follows them in operator '
     'position, so `<starts>` and `<end-date>` stay perfectly usable as '
     'variable names. `not` on its own is still the unary negation.',
     ['no'],
     ['they are reserved words',
      'cannot be used as a variable name']),

    ('explain-012', 'conditionals',
     'Do `when` and `where` understand the same operators?',
     'Yes. They take the same set — `in` / `not in`, `starts with`, `ends '
     'with`, `contains`, `matches`, `before`, `after`, `subset of`. They had '
     'diverged, so a predicate that could filter a collection could not guard '
     'a statement; that is fixed, and a condition written for one works in '
     'the other.',
     ['same'],
     ['where supports fewer operators',
      'only when supports them']),

    ('explain-013', 'conditionals',
     'Can the body of a `for each` loop update a counter that was created '
     'before the loop?',
     'No — that is an immutability violation and `aro check` rejects it: '
     '"Cannot rebind variable … variables are immutable". A `while` body may '
     'rebind, which is how an accumulator loop is written. For a running '
     'total over a collection, reach for a `sum` qualifier or the Reduce '
     'action instead of a counter.',
     ['immutable'],
     ['yes, that is allowed',
      'rebinding is allowed in both']),

    ('explain-014', 'conditionals',
     'What does `subset of` give me that `contains` does not?',
     '`contains` asks about one element; `subset of` asks about a whole '
     'collection at once, with set semantics — a duplicate on the left does '
     'not create a new member, and the empty set is a subset of everything. '
     'It is an operator rather than a qualifier because it answers a question '
     'instead of producing a collection, and it works in `where` as well as '
     '`when`.',
     ['subset of', 'operator'],
     ['it is a qualifier',
      'subset-of qualifier']),

    ('explain-015', 'configuration',
     'I want the HTTP client to allow two requests in flight and no more than '
     'five a second. Why is that one statement and not two?',
     'Because two Configure statements naming the same category would rebind '
     'an immutable binding. Several settings for one category go in one '
     'object: `Configure the <http-client> with { concurrency: 2, rate: '
     '"5/s" }.` A ceiling and a rate are different limits and both apply — '
     'one request at a time still exceeds a per-minute quota.',
     ['one object', 'immutable'],
     ['two statements is fine',
      'either way works']),

    ('explain-016', 'configuration',
     'What happens to work that arrives when the application concurrency '
     'ceiling is already full?',
     'It queues. The ceiling never fails a request and never drops work — '
     '`Configure the <application: concurrency> with 8.` bounds how much runs '
     'at once, and the rest waits. Work started *underneath* a slot-holder '
     'runs under that slot, which is what keeps the ceiling deadlock-free.',
     ['queue'],
     ['the work is rejected',
      'it throws when full',
      'the request is dropped']),

    ('explain-017', 'configuration',
     'Why is the scope in `Configure the <cart-repository: scope> with '
     '"session".` a quoted string rather than a bare word?',
     'Because the argument is an expression, so a bare `session` would be '
     'read as a variable reference and fail. The scope value is a string. '
     'Declare and Attach are in the must-run-for-effect set for the same '
     'reason: the executor would otherwise bind the expression and never run '
     'the action.',
     ['string', 'variable reference'],
     ['either form works',
      'a bare word is preferred']),

    ('explain-018', 'configuration',
     'What does a session-scoped repository do when it cannot work out who '
     'the caller is?',
     'It throws. Never the application-wide repository, never a silently '
     'empty one — those are the two answers that would turn a scoping mistake '
     'into a data leak or a mystery. `aro check` reports the statically '
     'visible cases: a session repository in Application-Start or a file '
     'handler, a connection repository on an HTTP route, conflicting '
     'declarations.',
     ['throw'],
     ['falls back to the application',
      'no error is raised']),

    ('explain-019', 'configuration',
     'Is `Configure the <application: concurrency> with 8.` the same thing as '
     '`with <concurrency: 8>` on a loop?',
     'No. The loop modifier bounds that one loop; Configure bounds the whole '
     'application — every triggered feature set and every parallel for-each '
     'iteration that is not already running inside a slot. ARO_CONCURRENCY '
     'sets the same application-wide ceiling from the environment.',
     ['loop', 'application'],
     ['they are equivalent',
      'they are interchangeable']),

    ('explain-020', 'rest',
     'I wrote the handlers but no port opens when I run the application. '
     'What is missing?',
     'The contract. ARO is contract-first: with no `openapi.yaml` the HTTP '
     'server does not start and no port is opened. Routes come from the '
     "contract's `operationId` values, and a feature set is wired to a route "
     'by being *named* after the operationId. No contract, no server.',
     ['openapi.yaml', 'operationId'],
     ['Start the <http-server> is enough',
      'add a port number to the Start statement']),

    ('explain-021', 'rest',
     'How does a request body reach a handler, and when does its size limit '
     'apply?',
     '`Extract the <upload> from the <request: body>.` binds it. The limit '
     'applies only when the feature set *reads* it — a field access, Compute, '
     'Store, Log, a `when` guard — because that is what turns a stream into a '
     'value. A handler that only moves the body (Write to a file, Send, '
     'Return, Emit, for each) never builds it in memory and is bounded by the '
     'sink, not by a limit. Per route it is `x-aro-max-body`, default 1 MB.',
     ['request: body', 'x-aro-max-body'],
     ['the limit is always 1 MB',
      'the limit always applies']),

    ('explain-022', 'rest',
     'A path parameter and a query parameter: how do the two statements '
     'differ?',
     'Both are Extract, and the source names which collection to read: '
     '`Extract the <id> from the <pathParameters: id>.` for a segment of the '
     'URL declared in the contract, and the query parameters for the part '
     'after the `?`. The contract decides which is which; the handler just '
     'names the right source.',
     ['pathParameters'],
     ['they read the same source',
      'ARO cannot read query parameters']),

    ('explain-023', 'rest',
     'I return `<TooManyRequests: status>` and the client sees 200. Is that '
     'expected?',
     'No, and it was a real bug: two hard-coded switches disagreed about the '
     'name list and both fell through to 200, so a rate-limit body shipped '
     'with a success code. Status names now come from one catalogue, read by '
     'the interpreter, the compiled binary and `aro check` alike. Case and '
     'separators do not distinguish names, and a misspelling within a typo of '
     'a real name is a check warning.',
     ['status', 'catalog'],
     ['200 is the correct code',
      'that is expected behaviour']),

    ('explain-024', 'rest',
     'Why is a feature set called `listInvoices` rather than something '
     'readable like "List Invoices"?',
     'Because the business activity pattern that wires a feature set to an '
     'HTTP route is "the name equals an operationId in the contract". '
     '`listInvoices` is matched against `operationId: listInvoices`; "List '
     'Invoices" is not. Readability lives in the business activity after the '
     'colon — `(listInvoices: Billing API)`.',
     ['operationId'],
     ['any feature-set name works',
      'the router ignores the name']),

    ('explain-025', 'rest',
     'Does a cookie in the request satisfy an `apiKey in: cookie` security '
     'scheme?',
     'No — a *validated session* does. The cookie being present proves '
     'nothing; the runtime mints the id with a CSPRNG, signs the cookie, '
     'validates it on every request, refreshes last-seen, rotates on Attach '
     'and evicts on disconnect and expiry. The scheme is satisfied by that '
     'validation passing.',
     ['validated session'],
     ['the presence of the cookie is enough',
      'yes, the cookie alone satisfies it']),

    ('explain-026', 'repositories',
     'What does a Retrieve that matches nothing do — throw, or bind '
     'something?',
     'It binds. With no `where` clause, or a `where` that matches nothing, '
     'you get an empty list; with a `where` that matches exactly one row you '
     'get that record rather than a one-element list. The only throw on that '
     'path is a repository that does not exist. Guard on the result — the '
     'statement does not fail for you.',
     ['empty list'],
     ['it throws when nothing matches',
      'it raises an error when nothing matches']),

    ('explain-027', 'repositories',
     'Where does a repository come from? I never declared one.',
     'Naming it is declaring it. `Store the <machine> into the '
     '<machines-repository>.` creates the repository on first use, and it is '
     'application-scoped unless a Configure statement says otherwise. A '
     '`.store` file beside the application seeds a repository of the matching '
     'name with YAML data, read-only unless its permissions say otherwise.',
     ['.store'],
     ['it must be declared first',
      'CREATE TABLE']),

    ('explain-028', 'repositories',
     'How do I get told when a repository changes, without the writer knowing '
     'about me?',
     'Give a feature set the business activity "<repository-name> Observer". '
     'The event bus routes store, update and delete on that repository to it. '
     'The writer emits nothing and names nobody; the wiring is the activity '
     'name.',
     ['Observer'],
     ['subscribe to the repository',
      'register a callback']),

    ('explain-029', 'repositories',
     'A handler does `Store the <item> into the <cart-repository>.` and '
     'nothing about sessions. How does the write reach the right customer?',
     'Through the declaration, not the statement. `Configure the '
     '<cart-repository: scope> with "session".` says the repository is '
     'partitioned per caller, and the same Store statement then writes to the '
     "calling caller's partition over HTTP, WebSocket and TCP alike. Handlers "
     'deliberately do not restate the scope.',
     ['scope', 'session'],
     ['pass the session id as an argument',
      'add a where clause on the session']),

    ('explain-030', 'tests',
     'Where do ARO tests live, and what stops them ending up in a compiled '
     'binary?',
     'Beside the code they test, in the same application directory, and they '
     'are identified by a business activity ending in `Test` or `Tests` — '
     '`(ten-percent: Pricing Test)`. `aro test` runs them; `aro build` strips '
     'them out of the native binary, so they are interpreter-only by '
     'construction rather than by a build flag anyone has to remember.',
     ['Test', 'strip'],
     ['a separate tests directory',
      'pass a test flag to aro build']),

    ('explain-031', 'tests',
     'Which four actions make up an ARO-0015 test, and which of them asserts?',
     'Given binds test data, When executes a named feature set and captures '
     'its result, Then asserts a value against an expectation, and Assert is '
     'the direct equality form of the same assertion. Then and Assert are the '
     'assertions; Given and When are setup. There is no setup or teardown '
     'hook — everything inside the test is the test.',
     ['Given', 'Then', 'Assert'],
     ['beforeEach',
      'a fixture block']),

    ('explain-032', 'tests',
     'Why does an ARO test have no setup or teardown block?',
     'Because everything inside the test *is* the test. A Given statement is '
     'ordinary setup written where you can see it, and an assertion reads the '
     'values the statements above it produced. Shared setup that happens '
     'somewhere else is the thing the design is rejecting, not an omission.',
     ['inside the test'],
     ['beforeEach',
      'ARO supports teardown']),

    ('explain-033', 'plugin',
     'Which directory do plugins load from, and why does the capitalisation '
     'matter?',
     '`Plugins/` — capital P — with one subdirectory per plugin and a '
     '`plugin.yaml` in each. A lowercase `plugins/` is still read with a '
     'deprecation warning and will stop being read. The capitalisation '
     'matters because on a case-insensitive filesystem the two are one '
     'directory and on Linux they are two, so a project used to load a '
     "different set of plugins depending on the developer's machine.",
     ['Plugins/', 'plugin.yaml'],
     ['either spelling is fine',
      'the case does not matter']),

    ('explain-034', 'plugin',
     'A plugin manifest has a root-level `handle:` and a `handler:` inside '
     '`provides:`, and they disagree. Which one wins?',
     'The root-level `handle:` — and the deprecation warning says so. '
     '`handler:` inside `provides:` is the legacy spelling; it still works, '
     'it warns even when a root-level handle is also present, and when the '
     'two name different namespaces the root-level one is what qualifiers and '
     'actions resolve under.',
     ['handle'],
     ['the handler field wins',
      'the last one wins']),

    ('explain-035', 'plugin',
     'A Geo plugin exposes a qualifier. `Compute the <grid: geo.grid-ref> '
     'from <position>.` parses and `Compute the <grid: geo.to-grid> from '
     '<position>.` does not. What is the difference?',
     'The second one begins its qualifier name with `to`, which the lexer '
     'reads as a preposition, so the statement comes apart at `.to` — the '
     'error is "Expected \'>\'" followed by "Expected action verb … but got '
     'preposition(to)". A namespaced qualifier name cannot start with a word '
     'the lexer treats as a preposition. Name it `grid-ref`, or anything that '
     'does not open with to / from / with / for / into / at / by / in.',
     ['preposition', 'lexer'],
     ['both parse', 'the plugin is not installed']),

    ('explain-036', 'plugin',
     'What are the four C entry points every plugin ends up exposing, '
     'whatever language it is written in?',
     '`aro_plugin_info` returns the metadata JSON, `aro_plugin_execute` '
     'dispatches an action, `aro_plugin_qualifier` dispatches a qualifier, '
     'and `aro_plugin_free` releases a string the host is done with. The '
     'Swift, Rust, C and Python SDKs all generate these; the ABI is what the '
     'host actually talks to.',
     ['aro_plugin_info', 'aro_plugin_execute', 'aro_plugin_free'],
     ['there is no C ABI']),

    ('explain-037', 'plugin',
     'Why does `aro build --static` refuse a Python plugin, and what makes it '
     'build anyway?',
     'Because --static promises one file you can copy, and a Python plugin '
     'needs an interpreter, a libpython and a standard library resolved from '
     'the build machine — so the binary would look standalone and die on the '
     'target. Point ARO_STATIC_PYTHON at a CPython distribution with a *real* '
     'static libpython archive and its stdlib and it carries them instead; '
     'ARO_ALLOW_EMBEDDED_PYTHON=1 builds anyway for people who run where they '
     'build. A plugin needing a native wheel still cannot be embedded.',
     ['ARO_STATIC_PYTHON'],
     ['it never refuses',
      'there is nothing you can do']),

    ('explain-038', 'plugin',
     'Which plugin languages can be baked into a static binary and which ship '
     'beside it?',
     '--static (the default) bakes native plugins in: a Swift package, C '
     'sources and a Rust staticlib all become object files linked into the '
     'binary, with symbols renamed so several can coexist, and nothing is '
     'dlopened at run time. --dynamic ships the shared library next to the '
     'binary and loads it at startup the way the interpreter does. Python is '
     'the exception in both modes.',
     ['static', 'dynamic'],
     ['all plugins are dlopened',
      'no plugin can be linked statically']),

    ('explain-039', 'actions',
     'Store, Log, Send and Write read like exports. Why are they classified '
     'RESPONSE?',
     'Because the RESPONSE role is about data-flow direction — internal to '
     'external — and that is what all four do. It is a known, deliberate '
     'inconsistency '
     'rather than a typo: roles drive the data-flow analysis, so '
     'reclassifying one would change behaviour. EXPORT is reserved for making '
     'symbols globally accessible or exporting data: Publish, Emit, Commit, '
     'Push, Tag, Schedule.',
     ['RESPONSE', 'deliberate'],
     ['should be reclassified',
      'it is a bug']),

    ('explain-040', 'actions',
     'What happens if I invent a Compute qualifier that does not exist?',
     'It is an error, and the message names the closest real qualifier. The '
     'qualifier namespace is closed: a name has to resolve to a built-in, a '
     'plugin qualifier (`handle.qualifier`), a chain, or a date offset. It '
     'used to return the input unchanged, which meant an invented qualifier '
     'compiled, passed `aro check`, exited OK, and printed the wrong value.',
     ['closed', 'error'],
     ['it returns the input unchanged',
      'it is silently ignored']),

    ('explain-041', 'actions',
     'Is sorting a list a Compute qualifier?',
     'No — Sort is an action: `Sort the <ordered> for the <values>.` So are '
     'Reverse and element access (`Extract the <first-item: first> from the '
     '<values>.`). The qualifier slot selects an *operation* on the value, '
     'which is why a result type uses `as` instead: `Compute the <n> as Float '
     'from <s>.`',
     ['action'],
     ['Compute the <sorted: sort>',
      'yes, sorting is a qualifier']),

    ('explain-042', 'actions',
     'I wrote `Map the <discounted> from the <items> with <item> * 0.9.` and '
     'it will not check. Why?',
     'Because Map takes a *field name*, not an expression — `Map the <names> '
     'from the <users> with name.` and `Map the <names: name> from the '
     '<users>.` are the same statement. There is no per-element binding, so '
     '`<item>` has nothing to range over. Use `for each` when you need to '
     'compute per element.',
     ['field name', 'for each'],
     ['that statement is valid',
      'item is bound automatically']),

    ('explain-043', 'actions',
     'Why does Compare bind a new result instead of updating one of its '
     'operands?',
     'Because the older two-operand spelling tried to rebind its own first '
     'operand, which immutability forbids — it could never run. `Compare the '
     '<tally> from the <a> against the <b>.` takes both operands as inputs '
     'and binds a fresh name: `<tally: matches>` is the boolean and `<tally: '
     'result>` is equal / less / greater.',
     ['immutab', 'matches'],
     ['it does update its operand',
      'it rebinds the first operand']),

    ('explain-044', 'actions',
     '`Sort the <ordered> for the <loads>.` dies at run time when the loads '
     'are records rather than numbers. What is the fix?',
     'Sort compares values, and a record is not comparable, so pull the field '
     'you are ordering by out first: `Map the <tonnages> from the <loads> '
     'with t.` and then `Sort the <ordered> for the <tonnages>.` Note that '
     '`aro check` is happy with the record version — it is a run-time '
     'failure, reported as "Cannot sort the ordered for the loads" with the '
     'records in the trace.',
     ['Map', 'run'],
     ['Sort takes a field name', 'add a by clause to Sort']),

    ('explain-045', 'actions',
     'Which verbs can open a statement without being actions at all?',
     'The language keywords: `Require`, `import`, `Publish as`, `match` / '
     '`case` / `otherwise`, `for each`, `while`, `break`, `when`, `where`. '
     'They are grammar rather than registry entries, so they have no role, no '
     'prepositions and no entry in `aro actions` — which explains them '
     'instead of reporting "no action named".',
     ['Require', 'Publish', 'match'],
     ['they are actions',
      'aro actions lists them']),

    ('explain-046', 'execution',
     'Two statements in a feature set each take two seconds and neither reads '
     "the other's result. How long does the feature set take?",
     'About two seconds, not four. Statements start in source order and the '
     'program waits for one at the *first read of its result*, so '
     'independent statements overlap. ARO_NO_DEFER=1 turns that off, which is '
     'the fastest way to find out whether a suspected bug is order-related.',
     ['overlap', 'first read'],
     ['about four seconds',
      'strictly sequential']),

    ('explain-047', 'execution',
     'If statements can overlap, why does my Log output still come out in the '
     'order I wrote it?',
     'Because effects never defer. Log, Store, Emit, Send, Publish and Return '
     'run at their own statement and force whatever they read first, so '
     'observable output stays in source order. Deferral is an allowlist of '
     'value-producing verbs, and Sleep is deliberately left off it because '
     'the delay *is* the effect.',
     ['effect', 'source order'],
     ['the output order is undefined',
      'you have to add a barrier']),

    ('explain-048', 'execution',
     'A deferred statement fails and nothing ever reads its result. Is the '
     'failure lost?',
     'No. Feature-set exit forces whatever is still outstanding, so a failure '
     'nobody read is still reported, attributed to the statement that caused '
     'it rather than to the exit. A force that takes too long also warns, '
     'after ARO_FORCE_WARN_SECONDS.',
     ['exit', 'forc'],
     ['it is silently discarded',
      'the failure is lost']),

    ('explain-049', 'architecture',
     'I pointed `aro run` at a directory of several applications and it '
     'refused. Why, and what do I run instead?',
     'Because a directory of applications is not an application: several '
     'Application-Start feature sets in different subdirectories is an error, '
     'and the message names one to point at instead. For checking them all, '
     '`aro check --recursive` checks each separately — without it every .aro '
     'file under the path is pooled into one pseudo-application and siblings '
     'appear to share feature sets and entry points.',
     ['--recursive'],
     ['it should work',
      'pass a glob instead']),

    ('explain-050', 'architecture',
     'ARO has no imports inside an application. What is the `import` keyword '
     'for then?',
     'Pulling in a *separate* application. `import ../ModuleA` makes every '
     'feature set, type and published variable of that application visible, '
     'and it is the one place a path appears in ARO source — resolved '
     "relative to the importing file's directory. There are no visibility "
     'modifiers and no partial imports.',
     ['separate'],
     ['importing a file inside the application',
      'required at the top of every .aro file']),

    ('explain-051', 'actions',
     'Why does Group quote the field it partitions on — `by "clamp"` — while '
     'Map does not — `with t`?',
     'Because they are different clauses, not two spellings of one. Group '
     'takes a `by` clause whose argument is a string literal naming the '
     'field; Map takes the field as a bare name after `with`, and the same '
     'thing can be written in its qualifier slot instead: `Map the <tonnages: '
     't> from the <loads>.` Writing Group with a bare field name is a parse '
     'error, and writing Map with an expression is a check error, because '
     'neither has a per-element binding to evaluate one against.',
     ['by', 'with'],
     ['they are interchangeable', 'quote the field for both']),

    ('explain-052', 'files',
     'Does `extension` include the dot, and what does it say about a dotfile?',
     'No dot — `extension` of "lock-gauge.tsv" is "tsv". A dotfile is a name '
     'rather than an extension, so ".bashrc" has no extension. The path '
     'qualifiers are pure functions: none of them touches the filesystem, and '
     '`dirname` of a bare filename is ".".',
     ['no'],
     ['it includes the dot',
      'with the leading dot']),

    ('explain-053', 'files',
     'What does path-join do when the right-hand component is absolute?',
     'It joins anyway: "/uploads" and "/etc/passwd" give '
     '"/uploads/etc/passwd". That is deliberately unlike Python, where an '
     'absolute right-hand side discards the left — because the call this '
     'exists for is joining a *trusted* directory to an *untrusted* name, and '
     'resetting the path there is the bug.',
     ['/uploads/etc/passwd'],
     ['the left side is discarded',
      'the same as python']),

    ('explain-054', 'text',
     'A template file ends in `.tpl` and emits HTML. Is what I print into it '
     'escaped?',
     'No. Escaping follows the extension: `.html` and `.htm` escape what they '
     'print, `.tpl`, `.txt` and `.md` do not — so a `.tpl` emitting HTML '
     'still needs `html-escape` on the values. Both output forms follow the '
     'same rule, and each opts out its own way: `<template: raw>` for Print, '
     'the `| raw` filter for the `{{ }}` shorthand. Do not hand-escape into '
     'an escaping template, or the reader sees the escaped escapes.',
     ['html-escape', '.tpl'],
     ['yes, it is escaped',
      'all templates escape']),

    ('explain-055', 'text',
     'Why does hashing a 4 GB upload not need 4 GB of memory?',
     'Because the folding qualifiers consume the body chunk by chunk — '
     'sha256, length and lines all do — so hashing costs a chunk, and it '
     "hashes the upload's bytes rather than a rendering of its parsed form. "
     'That is the same distinction the body limits rest on: moving a body '
     'streams, reading one materialises.',
     ['chunk'],
     ['the whole body is loaded',
      'you need 4 GB of memory']),
]
