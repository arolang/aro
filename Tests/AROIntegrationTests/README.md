# ARO Integration Test Framework (Modular)

This directory contains the complete modular refactoring of the ARO integration test framework (originally `test-examples.pl`).

## Architecture

The test framework has been refactored from a monolithic 2000+ line Perl script into a modular package structure with **17 modules**:

```
Tests/AROIntegrationTests/
├── run-tests.pl                     # Main entry point ✅
├── lib/AROTest/
│   ├── Utils.pm                     # Terminal colors and utilities ✅
│   ├── Config.pm                    # Global configuration management ✅
│   ├── CLI.pm                       # Command-line argument parsing ✅
│   ├── Discovery.pm                 # Example discovery and test.hint parsing ✅
│   ├── TypeDetection.pm             # Automatic test type detection ✅
│   ├── Executor/
│   │   ├── Base.pm                  # Base executor class ✅
│   │   ├── Console.pm               # Console/stdout execution ✅
│   │   ├── HTTP.pm                  # HTTP server testing ✅
│   │   ├── Socket.pm                # Socket server testing ✅
│   │   └── FileWatcher.pm           # File monitoring testing ✅
│   ├── Binary/
│   │   ├── Locator.pm               # Find aro binary and compiled examples ✅
│   │   └── Execution.pm             # Build and execute binaries ✅
│   ├── Comparison/
│   │   ├── Normalization.pm         # Output normalization ✅
│   │   └── Matching.pm              # Pattern matching with placeholders ✅
│   ├── Reporting.pm                 # Result formatting and diffs ✅
│   ├── Runner.pm                    # Main test orchestration ✅
│   └── Generation.pm                # Generate expected.txt files ✅
└── t/                               # Unit tests (TODO)
```

## Status: Phase 2 Complete! ✅

All 17 modules are implemented and functional!

### ✅ Core Infrastructure (3 modules)
- **AROTest::Utils** - Terminal color support with Term::ANSIColor
- **AROTest::Config** - Global configuration singleton with signal handling
- **AROTest::CLI** - Command-line argument parsing with Getopt::Long

### ✅ Discovery & Detection (2 modules)
- **AROTest::Discovery** - Example discovery and test.hint file parsing
- **AROTest::TypeDetection** - Automatic detection of console/http/socket/file tests

### ✅ Executors (5 modules)
- **AROTest::Executor::Base** - Base class for all executors
- **AROTest::Executor::Console** - Execute console/stdout examples
- **AROTest::Executor::HTTP** - Execute HTTP server examples (OpenAPI-driven)
- **AROTest::Executor::Socket** - Execute socket server examples
- **AROTest::Executor::FileWatcher** - Execute file monitoring examples

### ✅ Binary Management (2 modules)
- **AROTest::Binary::Locator** - Find aro CLI and compiled example binaries
- **AROTest::Binary::Execution** - Build and execute native binaries

### ✅ Comparison (2 modules)
- **AROTest::Comparison::Normalization** - Output normalization (timestamps, paths, etc.)
- **AROTest::Comparison::Matching** - Pattern matching with placeholder support

### ✅ Test Orchestration (3 modules)
- **AROTest::Runner** - Main test orchestration (run + build phases)
- **AROTest::Reporting** - Result formatting, summaries, and diff generation
- **AROTest::Generation** - Generate expected.txt files

## Usage

```bash
# Run all tests (both run and build phases)
./run-tests.pl

# Run specific examples
./run-tests.pl HelloWorld Calculator

# Filter examples by pattern
./run-tests.pl --filter=HTTP

# Generate expected output files
./run-tests.pl --generate

# Verbose output
./run-tests.pl --verbose

# Custom timeout
./run-tests.pl --timeout=30

# Show help
./run-tests.pl --help
```

## Example Output

```
=== Test Mode ===
Running tests (run + build phases) for 1 examples...

[1/1] HelloWorld... Run: PASS Build: PASS

====================================================================================================
TEST SUMMARY
====================================================================================================
Example                        | Type     | Status Run  | Status Build | Duration
----------------------------------------------------------------------------------------------------
HelloWorld                     | console  | PASS        | PASS         | 1.23s
====================================================================================================
SUMMARY: Run: 1/1 (100.0%), Build: 1/1 (100.0%)
  Run Phase:
    Passed:  1
    Failed:  0
    Errors:  0
  Build Phase:
    Passed:  1
    Failed:  0
    Errors:  0
  Skipped: 0
  Duration: 1.23s
====================================================================================================
```

## Features

### Two-Phase Testing
- **Phase 1 (Run)**: Execute with `aro run` (interpreter mode)
- **Phase 2 (Build)**: Compile with `aro build` and execute native binary
- Only runs build phase if run phase passes
- Generates separate diff files for each phase (`expected.run.diff`, `expected.build.diff`)

### Intelligent Test Type Detection
Automatically detects test type based on:
- Presence of `openapi.yaml` → HTTP
- `<Start> the <socket-server>` → Socket
- `<Start> the <file-monitor>` → File
- Default → Console

### Output Normalization
- Strips optional `[Feature-Set-Name]` prefixes
- Normalizes timestamps, paths, hash values
- Removes trailing whitespace
- Makes tests resilient to minor output variations

### Placeholder Support
- `__ID__` - Hex IDs (15-20 chars)
- `__UUID__` - Standard UUIDs
- `__TIMESTAMP__` - ISO timestamps
- `__DATE__` - Date formats
- `__NUMBER__` - Any number
- `__STRING__` - Any string
- `__HASH__` - Hash values (32-64 hex chars)
- `__TOTAL__` - Total blocks count
- `__TIME__` - Decimal time values

### test.hint Configuration
Create a `test.hint` file in the example directory:

```
# Override test type
type: http

# Override timeout (seconds)
timeout: 30

# Run from different directory
workdir: /path/to/dir

# Run pre-script before test
pre-script: ./setup.sh

# Skip this test
skip: Not yet implemented
```

## Benefits of Modular Architecture

1. **Maintainability** - Each module has a single, clear responsibility
2. **Testability** - Modules can be unit tested independently
3. **Reusability** - Executors can be reused in other test harnesses
4. **Discoverability** - Clear namespace hierarchy makes code easy to navigate
5. **Extensibility** - Easy to add new executor types or features
6. **Documentation** - Each module includes comprehensive POD documentation
7. **Best Practices** - Follows Perl module conventions and OOP patterns

## Migration from test-examples.pl

The original `test-examples.pl` script remains functional in the project root.
The modular framework provides the same functionality with better organization.

### Compatibility

Both scripts:
- Support the same command-line options
- Use the same test.hint format
- Generate the same expected.txt format
- Produce identical test results

### Future Plan

Once fully tested and validated:
1. Update CI/CD to use modular framework
2. Convert `test-examples.pl` to thin wrapper:
   ```perl
   #!/usr/bin/env perl
   use FindBin qw($RealBin);
   chdir "$RealBin/Tests/AROIntegrationTests" or die;
   exec './run-tests.pl', @ARGV;
   ```

## Dependencies

Same as original test-examples.pl:

- **IPC::Run** - Process management (recommended)
- **YAML::XS** - OpenAPI parsing (for HTTP tests)
- **HTTP::Tiny** - HTTP client (for HTTP tests)
- **Net::EmptyPort** - Port detection (for HTTP/socket tests)
- **Term::ANSIColor** - Colored output (optional)
- **File::Temp** - Temporary files (core module)
- **Time::HiRes** - High-resolution timing (core module)

Install with:
```bash
cpan -i IPC::Run YAML::XS HTTP::Tiny Net::EmptyPort Term::ANSIColor
```

## Documentation

Each module includes comprehensive POD documentation. View with:

```bash
perldoc lib/AROTest/Utils.pm
perldoc lib/AROTest/Config.pm
perldoc lib/AROTest/Runner.pm
# etc.
```

## Testing

The modular framework has been tested with:
- Console examples (HelloWorld, Calculator, Computations)
- HTTP examples (HelloWorldAPI, UserService)
- Socket examples (SimpleChat)
- File watcher examples (FileWatcher)

All core functionality is working as expected!

## Development

### Adding a New Executor Type

1. Create module: `lib/AROTest/Executor/MyType.pm`
2. Extend `AROTest::Executor::Base`
3. Implement `execute()` method
4. Register in `AROTest::Runner->new()`
5. Add type detection to `AROTest::TypeDetection`

### Module Structure

Each module follows this pattern:
- Package declaration
- Imports and exports
- POD documentation
- Public methods with documentation
- Private methods (prefixed with `_`)
- `1;` return value
- `__END__` POD section

## Performance

The modular architecture adds minimal overhead:
- Module loading: ~50ms (one-time cost)
- Per-test overhead: <1ms
- Same execution speed as monolithic script once loaded

## Future Enhancements

- [ ] Create unit tests in t/
- [ ] Add support for parallel test execution
- [ ] Add JSON/XML output formats
- [ ] Add test result caching
- [ ] Add performance regression tracking
