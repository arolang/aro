# ARO Integration Test Framework (Modular)

This directory contains the modular refactoring of the ARO integration test framework (originally `test-examples.pl`).

## Architecture

The test framework has been refactored from a monolithic 2000+ line Perl script into a modular package structure:

```
Tests/AROIntegrationTests/
├── run-tests.pl              # Main entry point
├── lib/
│   └── AROTest/
│       ├── Utils.pm          # Terminal colors and utilities
│       ├── Config.pm         # Global configuration management
│       ├── CLI.pm            # Command-line argument parsing
│       ├── Discovery.pm      # Example discovery and test.hint parsing
│       ├── TypeDetection.pm  # Automatic test type detection
│       ├── Binary/
│       │   └── Locator.pm    # Find aro binary and compiled examples
│       └── Comparison/
│           ├── Normalization.pm  # Output normalization
│           └── Matching.pm       # Pattern matching with placeholders
└── t/                        # Unit tests (TODO)
```

## Implemented Modules (Phase 1)

### ✅ Core Modules
- **AROTest::Utils** - Terminal color support with Term::ANSIColor
- **AROTest::Config** - Global configuration singleton with signal handling
- **AROTest::CLI** - Command-line argument parsing with Getopt::Long

### ✅ Discovery & Detection
- **AROTest::Discovery** - Example discovery and test.hint file parsing
- **AROTest::TypeDetection** - Automatic detection of console/http/socket/file tests

### ✅ Binary Management
- **AROTest::Binary::Locator** - Find aro CLI and compiled example binaries

### ✅ Comparison
- **AROTest::Comparison::Normalization** - Output normalization (timestamps, paths, etc.)
- **AROTest::Comparison::Matching** - Pattern matching with placeholder support

## Usage

```bash
# Show help
./run-tests.pl --help

# List examples (verbose mode)
./run-tests.pl --verbose --filter=Hello

# Test specific examples
./run-tests.pl Calculator Computations

# Filter examples by pattern
./run-tests.pl --filter=HTTP
```

## Next Steps (Phase 2)

### TODO: Executor Modules
- [ ] AROTest::Executor::Base - Base executor class
- [ ] AROTest::Executor::Console - Console/stdout execution
- [ ] AROTest::Executor::HTTP - HTTP server testing
- [ ] AROTest::Executor::Socket - Socket server testing
- [ ] AROTest::Executor::FileWatcher - File monitoring testing

### TODO: Core Functionality
- [ ] AROTest::Binary::Execution - Build and execute binaries
- [ ] AROTest::Runner - Main test orchestration
- [ ] AROTest::Reporting - Result formatting and diffs
- [ ] AROTest::Generation - Generate expected.txt files

### TODO: Documentation & Testing
- [ ] Create unit tests in t/
- [ ] Update documentation
- [ ] Create compatibility wrapper for old test-examples.pl
- [ ] Update CI/CD scripts

## Benefits of Modular Architecture

1. **Maintainability** - Each module has a single, clear responsibility
2. **Testability** - Modules can be unit tested independently
3. **Reusability** - Executors can be reused for different test harnesses
4. **Discoverability** - Clear namespace hierarchy makes code easy to find
5. **Extensibility** - Easy to add new executor types or features
6. **Documentation** - Each module has POD documentation

## Migration from test-examples.pl

The original `test-examples.pl` script is still functional in the project root.
Once all modules are implemented, it will be converted to a thin wrapper:

```perl
#!/usr/bin/env perl
# DEPRECATED: Use Tests/AROIntegrationTests/run-tests.pl instead
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

Install with:
```bash
cpan -i IPC::Run YAML::XS HTTP::Tiny Net::EmptyPort Term::ANSIColor
```

## Documentation

Each module includes comprehensive POD documentation. View with:

```bash
perldoc lib/AROTest/Utils.pm
perldoc lib/AROTest/Config.pm
# etc.
```
