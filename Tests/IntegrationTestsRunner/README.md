# IntegrationTestsRunner

End-to-end harness for the examples in `Examples/`. Replaces the monolithic
`test-examples.pl`; behaviour and CLI output are byte-identical.

## Run

```bash
# All examples, sequential
./run-tests.pl

# Specific examples
./run-tests.pl HelloWorld Calculator HTTPServer

# Pattern filter
./run-tests.pl --filter=HTTP

# Verbose (per-step logs)
./run-tests.pl --verbose

# Parallel pool. Examples with hardcoded ports (socket / socket-client /
# multiservice) run serially after the parallel batch finishes.
./run-tests.pl -j 4

# Refresh expected.txt for the listed examples
./run-tests.pl --generate HelloWorld
```

Each example runs in two modes — `aro run` (interpreter) and `aro build`
followed by executing the compiled binary — and both outputs must match
the same `expected.txt`. Test type (`console` / `http` / `socket` / `file`
/ `multiservice` / `multi-context`) is read from `test.hint` or detected
from `openapi.yaml` plus an `.aro` source grep. Pattern placeholders in
`expected.txt` cover dynamic values: `__TIMESTAMP__`, `__UUID__`,
`__NUMBER__`, `__HASH__`, `__DATE__`, `__STRING__`, `__TIME__`, `__ID__`,
`__TOTAL__`.

## Layout

```
Tests/IntegrationTestsRunner/
├── run-tests.pl                          # ~100-line entry: CLI parse, dispatch
└── lib/AROTest/
    ├── Utils.pm                          # platform flags, color, exe helpers
    ├── Config.pm                         # shared state, signal cleanup
    ├── Discovery.pm                      # Examples/ walker
    ├── Hint.pm                           # test.hint parser, testrun.log writer
    ├── Detect.pm                         # auto-detect test type
    ├── Binary.pm                         # find_aro_binary, build_example
    ├── Shell.pm                          # IPC::Run wrapper for sh snippets
    ├── Normalize.pm                      # output canonicalisation
    ├── Match.pm                          # pattern matching + placeholders
    ├── Reporting.pm                      # summary table + diff files
    ├── Pool.pm                           # fork pool, serial-must routing
    ├── Runner.pm                         # run_test, mode dispatch, retry
    ├── Generation.pm                     # --generate flow
    └── Executor/
        ├── Console.pm                    # aro run / compiled binary
        ├── HTTP.pm                       # OpenAPI-driven request workflow
        ├── Socket.pm                     # TCP socket server + client
        ├── FileWatcher.pm                # file-monitor poke-and-watch
        ├── MultiService.pm               # HTTP + socket + file in one app
        └── MultiContext.pm               # console + http + debug renders
```

## Required Perl modules

| Module             | Purpose                          | Required? |
|--------------------|----------------------------------|-----------|
| IPC::Run           | Timed subprocess execution       | yes       |
| YAML::XS           | Parse `openapi.yaml`             | for HTTP  |
| HTTP::Tiny        | Issue test requests              | for HTTP  |
| Net::EmptyPort     | Free-port allocation (parallel)  | recommended |
| Term::ANSIColor    | Coloured output                  | optional  |

Install missing modules with `cpan -i IPC::Run YAML::XS HTTP::Tiny Net::EmptyPort Term::ANSIColor`.
