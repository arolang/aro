#!/usr/bin/env perl
#
# ARO Examples Test Harness — entry point.
#
# This file is intentionally thin: it parses CLI options, resolves the
# project root, and hands control to the AROTest::* modules under lib/.
# All business logic — executors, comparators, reporting, the worker pool —
# lives in those modules. Output must remain byte-identical to the
# pre-refactor monolithic test-examples.pl; see Tests/IntegrationTestsRunner
# README and CI baselines.

use strict;
use warnings;
use v5.30;
use FindBin ();
use Getopt::Long;

use lib "$FindBin::RealBin/lib";
use AROTest::Config qw(%options $examples_dir install_signal_handlers);
use AROTest::Discovery qw(discover_examples);
use AROTest::Runner qw(run_all_tests);
use AROTest::Generation qw(generate_all_expected);

$| = 1;  # autoflush stdout — needed when piped/redirected

AROTest::Config::init_paths($FindBin::RealBin);

GetOptions(
    'generate'   => \$options{generate},
    'verbose|v'  => \$options{verbose},
    'timeout=i'  => \$options{timeout},
    'filter=s'   => \$options{filter},
    'jobs|j=i'   => \$options{jobs},
    'help|h'     => \$options{help},
) or die "Invalid options. Use --help for usage.\n";

die "--jobs must be >= 1 (got $options{jobs})\n" if $options{jobs} < 1;

if ($options{help}) {
    print_usage();
    exit 0;
}

install_signal_handlers();
main();

sub main {
    die "Examples directory not found: $examples_dir\n" unless -d $examples_dir;

    my @examples = @ARGV ? @ARGV : discover_examples();
    @examples = grep { /$options{filter}/i } @examples if $options{filter};
    die "No examples found matching criteria.\n" unless @examples;

    if ($options{generate}) {
        generate_all_expected(\@examples);
    } else {
        run_all_tests(\@examples);
    }
}

sub print_usage {
    print <<'USAGE';
ARO Examples Test Harness

Usage:
    ./run-tests.pl [OPTIONS] [EXAMPLE]

Options:
    --generate          Generate expected.txt files for all examples
    -v, --verbose       Show detailed output
    --timeout=N         Timeout in seconds for long-running examples (default: 60)
    --filter=PATTERN    Test only examples matching pattern
    -j, --jobs=N        Run up to N tests in parallel (default: 1).
                        Tests with hardcoded ports (socket / socket-client /
                        multiservice) always run serially after the pool.
    -h, --help          Show this help

Examples:
    # Generate all expected outputs
    ./run-tests.pl --generate

    # Run all tests
    ./run-tests.pl

    # Test only HTTP examples
    ./run-tests.pl --filter=HTTP

    # Test single example
    ./run-tests.pl HelloWorld

    # Verbose mode
    ./run-tests.pl --verbose

Required Perl Modules:
    IPC::Run           - Process management (recommended)
    YAML::XS           - OpenAPI parsing (for HTTP tests)
    HTTP::Tiny         - HTTP client (for HTTP tests)
    Net::EmptyPort     - Port detection (for HTTP/socket tests)
    Term::ANSIColor    - Colored output (optional)

Install with: cpan -i IPC::Run YAML::XS HTTP::Tiny Net::EmptyPort Term::ANSIColor
USAGE
}
