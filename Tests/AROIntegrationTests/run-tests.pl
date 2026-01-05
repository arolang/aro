#!/usr/bin/env perl
#
# ARO Integration Test Framework
# Modular test harness for ARO examples
#

use strict;
use warnings;
use v5.30;
use FindBin qw($RealBin);
use lib "$RealBin/lib";
use Time::HiRes qw(time);

# Import modules
use AROTest::CLI qw(parse_args print_usage);
use AROTest::Config;
use AROTest::Discovery qw(discover_examples);
use AROTest::Runner;
use AROTest::Reporting qw(print_summary create_diff_file);
use AROTest::Generation qw(generate_all_expected);

=head1 NAME

run-tests.pl - ARO Integration Test Framework

=head1 DESCRIPTION

Modular test harness for ARO language examples. Supports both interpreter
(aro run) and compiled binary (aro build) testing with two-phase validation.

=cut

# Main entry point
sub main {
    # Parse command-line arguments
    my ($options, $example_filters) = parse_args(@ARGV);

    # Show help if requested
    if ($options->{help}) {
        print_usage();
        exit 0;
    }

    # Create configuration
    my $config = AROTest::Config->new(%$options);

    # Verify examples directory exists
    unless (-d $config->examples_dir) {
        die "Examples directory not found: " . $config->examples_dir . "\n";
    }

    # Discover examples
    my @examples;
    if (@$example_filters) {
        # Use provided example names
        @examples = @$example_filters;
    } else {
        # Discover all examples
        @examples = discover_examples($config->examples_dir, $config->filter);
    }

    unless (@examples) {
        die "No examples found matching criteria.\n";
    }

    # Create runner
    my $runner = AROTest::Runner->new($config);

    # Run in appropriate mode
    if ($config->is_generate) {
        run_generate_mode($runner, $config, \@examples);
    } else {
        run_test_mode($runner, $config, \@examples);
    }
}

# Generate mode: create expected.txt files
sub run_generate_mode {
    my ($runner, $config, $examples) = @_;

    say "=== Generate Mode ===";
    say "Generating expected.txt files for " . scalar(@$examples) . " examples...";
    say "";

    generate_all_expected($examples, $runner, $config);
}

# Test mode: run and verify examples
sub run_test_mode {
    my ($runner, $config, $examples) = @_;

    say "=== Test Mode ===";
    say "Running tests (run + build phases) for " . scalar(@$examples) . " examples...";
    say "";

    my $start_time = time;

    # Run all tests
    my @results = $runner->run_all_tests(@$examples);

    my $total_duration = time - $start_time;

    # Print summary
    print_summary(\@results, $total_duration);

    # Create diff files for failures
    for my $result (@results) {
        # Create diff for run phase if failed
        if ($result->{run_status} eq 'FAIL' && $result->{run_actual}) {
            create_diff_file({
                status => 'FAIL',
                expected => $result->{run_expected},
                actual => $result->{run_actual},
                expected_file => $result->{expected_file},
            }, 'expected.run.diff');
        }

        # Create diff for build phase if failed
        if ($result->{build_status} eq 'FAIL' && $result->{build_actual}) {
            create_diff_file({
                status => 'FAIL',
                expected => $result->{build_expected},
                actual => $result->{build_actual},
                expected_file => $result->{expected_file},
            }, 'expected.build.diff');
        }
    }

    # Exit with appropriate code
    my $failed = grep {
        $_->{run_status} eq 'FAIL' || $_->{run_status} eq 'ERROR' ||
        $_->{build_status} eq 'FAIL' || $_->{build_status} eq 'ERROR'
    } @results;

    exit($failed > 0 ? 1 : 0);
}

# Run main
main() unless caller;

__END__

=head1 SYNOPSIS

    # Run all tests
    ./run-tests.pl

    # Run specific examples
    ./run-tests.pl HelloWorld Calculator

    # Filter examples by pattern
    ./run-tests.pl --filter=HTTP

    # Generate expected output files
    ./run-tests.pl --generate

    # Verbose output
    ./run-tests.pl --verbose

=head1 OPTIONS

=over 4

=item B<--generate>

Generate expected.txt files for all examples

=item B<-v, --verbose>

Show detailed output

=item B<--timeout=N>

Set timeout in seconds (default: 10)

=item B<--filter=PATTERN>

Test only examples matching pattern

=item B<-h, --help>

Show help message

=back

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
