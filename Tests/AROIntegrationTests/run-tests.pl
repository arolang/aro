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

# Import modules
use AROTest::CLI qw(parse_args print_usage);
use AROTest::Config;
use AROTest::Discovery qw(discover_examples read_test_hint);
use AROTest::TypeDetection qw(detect_type);
use AROTest::Binary::Locator qw(find_aro_binary);
use AROTest::Utils qw(colored);

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

    # Verify aro binary is available
    my $aro = find_aro_binary();
    say colored("Using ARO binary: $aro", 'cyan') if $config->is_verbose;

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

    # Show what we're going to test
    if ($config->is_verbose) {
        say colored("Found " . scalar(@examples) . " examples:", 'cyan');
        say "  - $_" for @examples;
        say "";
    }

    # Run in appropriate mode
    if ($config->is_generate) {
        say colored("=== Generate Mode ===", 'bold yellow');
        say "This will generate expected.txt files for all examples.";
        say colored("Not yet implemented - requires Generation module", 'red');
        # TODO: Call generation module
    } else {
        say colored("=== Test Mode ===", 'bold cyan');
        say "Running tests (run + build phases) for " . scalar(@examples) . " examples...";
        say "";
        say colored("Not yet fully implemented - requires Runner and Executor modules", 'yellow');

        # Demo: show what would be tested
        for my $example (@examples) {
            my $dir = File::Spec->catdir($config->examples_dir, $example);
            my $hints = read_test_hint($dir, $config);
            my $type = $hints->{type} || detect_type($dir);

            print "[$example] ";
            print colored("type=$type ", 'cyan');
            print "timeout=" . ($hints->{timeout} || $config->timeout) . "s ";
            print colored("SKIP", 'yellow') . " " if $hints->{skip};
            print "\n";
        }
    }

    say "";
    say colored("Modular test framework structure created!", 'bold green');
    say "Modules implemented:";
    say "  ✓ AROTest::Utils";
    say "  ✓ AROTest::Config";
    say "  ✓ AROTest::CLI";
    say "  ✓ AROTest::Discovery";
    say "  ✓ AROTest::TypeDetection";
    say "  ✓ AROTest::Binary::Locator";
    say "  ✓ AROTest::Comparison::Normalization";
    say "  ✓ AROTest::Comparison::Matching";
    say "";
    say "Next steps:";
    say "  - Implement Executor modules (Console, HTTP, Socket, FileWatcher)";
    say "  - Implement Binary::Execution module";
    say "  - Implement Runner module";
    say "  - Implement Reporting module";
    say "  - Implement Generation module";
}

# Run main
main() unless caller;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
