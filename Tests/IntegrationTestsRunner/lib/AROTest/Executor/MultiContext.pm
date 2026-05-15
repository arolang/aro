package AROTest::Executor::MultiContext;

# MultiContext executor: tests an example three ways — console, HTTP, and
# debug — comparing each output against its dedicated expected file
# (expected-console.txt / expected-http.txt / expected-debug.txt). Used by
# examples that intentionally render the same data in three contexts.

use strict;
use warnings;
use v5.30;
use File::Spec;
use Time::HiRes qw(time);
use Exporter 'import';

use AROTest::Config qw(%options $examples_dir);
use AROTest::Binary qw(build_example);
use AROTest::Normalize qw(normalize_output);
use AROTest::Match qw(matches_pattern);
use AROTest::Executor::Console qw(run_console_example_internal run_debug_example);
use AROTest::Executor::HTTP qw(run_http_example_internal);

our @EXPORT_OK = qw(test_multi_context_example);

sub test_multi_context_example {
    my ($example_name, $hints, $timeout) = @_;

    my $start_time = time;
    my $mode = $hints->{mode} || 'both';

    say "Testing $example_name (multi-context) in $mode mode..." if $options{verbose};

    my %interpreter_results;
    my %compiled_results;
    my $interpreter_failures = 0;
    my $compiled_failures = 0;

    # Determine which modes to test
    my @modes_to_test;
    if ($mode eq 'both') {
        @modes_to_test = ('interpreter', 'compiled');
    } elsif ($mode eq 'interpreter' || $mode eq 'compiled') {
        @modes_to_test = ($mode);
    } else {
        @modes_to_test = ('interpreter');  # Default
    }

    # Build binary if compiled mode is being tested
    if (grep { $_ eq 'compiled' } @modes_to_test) {
        my $build_result = build_example($example_name, $timeout, $hints->{workdir});

        if (!$build_result->{success}) {
            # Build failed - skip compiled mode tests
            say "  Binary build failed: $build_result->{error}" if $options{verbose};
            @modes_to_test = grep { $_ ne 'compiled' } @modes_to_test;

            # Mark compiled contexts as ERROR
            $compiled_results{console} = { status => 'ERROR', message => $build_result->{error} };
            $compiled_results{http} = { status => 'ERROR', message => $build_result->{error} };
            $compiled_results{debug} = { status => 'ERROR', message => $build_result->{error} };
            $compiled_failures = 1;
        }
    }

    for my $test_mode (@modes_to_test) {
        my %context_results;
        my $any_failures = 0;

        say "  Testing in $test_mode mode..." if $options{verbose};

        # Test 1: Console context (human)
        my $exp_console = File::Spec->catfile($examples_dir, $example_name, 'expected-console.txt');
        if (-f $exp_console) {
            say "    Testing console context..." if $options{verbose};
            my ($output, $error) = run_console_example_internal($example_name, $timeout, $test_mode, undef, $hints);

        if ($error) {
            $context_results{console} = {
                status => $error =~ /^SKIP/ ? 'SKIP' : 'ERROR',
                message => $error,
            };
            $any_failures = 1 unless $error =~ /^SKIP/;
        } else {
            # Read expected output
            open my $fh, '<', $exp_console or die "Cannot read $exp_console: $!";
            my $expected = do { local $/; <$fh> };
            close $fh;

            # Strip metadata header
            $expected =~ s/^#.*?\n---\n//s;

            # Normalize both
            my $output_normalized = normalize_output($output, 'console');
            my $expected_normalized = normalize_output($expected, 'console');

            # Trim whitespace
            $output_normalized =~ s/^\s+|\s+$//g;
            $expected_normalized =~ s/^\s+|\s+$//g;

            if (matches_pattern($output_normalized, $expected_normalized)) {
                $context_results{console} = { status => 'PASS', message => '' };
            } else {
                $context_results{console} = {
                    status => 'FAIL',
                    message => 'Console output mismatch',
                    expected => $expected_normalized,
                    actual => $output_normalized,
                };
                $any_failures = 1;

                # Debug output for console context mismatch
                if ($options{verbose} || $ENV{DEBUG_TEST_FAILURES}) {
                    say "  [CONSOLE MISMATCH]";
                    say "  Expected:";
                    say "  " . join("\n  ", split /\n/, substr($expected_normalized, 0, 500));
                    say "  Actual:";
                    say "  " . join("\n  ", split /\n/, substr($output_normalized, 0, 500));
                }
            }
        }
        }

        # Test 2: HTTP context (machine)
        my $exp_http = File::Spec->catfile($examples_dir, $example_name, 'expected-http.txt');
        if (-f $exp_http) {
            say "    Testing HTTP context..." if $options{verbose};
            my ($output, $error) = run_http_example_internal($example_name, $timeout, $test_mode, undef);

        if ($error) {
            $context_results{http} = {
                status => $error =~ /^SKIP/ ? 'SKIP' : 'ERROR',
                message => $error,
            };
            $any_failures = 1 unless $error =~ /^SKIP/;
        } else {
            # Read expected output
            open my $fh, '<', $exp_http or die "Cannot read $exp_http: $!";
            my $expected = do { local $/; <$fh> };
            close $fh;

            # Strip metadata header
            $expected =~ s/^#.*?\n---\n//s;

            # Normalize both
            my $output_normalized = normalize_output($output, 'http');
            my $expected_normalized = normalize_output($expected, 'http');

            # Trim whitespace
            $output_normalized =~ s/^\s+|\s+$//g;
            $expected_normalized =~ s/^\s+|\s+$//g;

            if (matches_pattern($output_normalized, $expected_normalized)) {
                $context_results{http} = { status => 'PASS', message => '' };
            } else {
                $context_results{http} = {
                    status => 'FAIL',
                    message => 'HTTP output mismatch',
                    expected => $expected_normalized,
                    actual => $output_normalized,
                };
                $any_failures = 1;

                # Debug output for HTTP context mismatch
                if ($options{verbose} || $ENV{DEBUG_TEST_FAILURES}) {
                    say "  [HTTP MISMATCH]";
                    say "  Expected:";
                    say "  " . substr($expected_normalized, 0, 500);
                    say "  Actual:";
                    say "  " . substr($output_normalized, 0, 500);
                }
            }
        }
    }

        # Test 3: Debug context (developer)
        my $exp_debug = File::Spec->catfile($examples_dir, $example_name, 'expected-debug.txt');
        if (-f $exp_debug) {
            say "    Testing debug context..." if $options{verbose};
            my ($output, $error) = run_debug_example($example_name, $timeout, $test_mode, undef, $hints);

        if ($error) {
            $context_results{debug} = {
                status => $error =~ /^SKIP/ ? 'SKIP' : 'ERROR',
                message => $error,
            };
            $any_failures = 1 unless $error =~ /^SKIP/;
        } else {
            # Read expected output
            open my $fh, '<', $exp_debug or die "Cannot read $exp_debug: $!";
            my $expected = do { local $/; <$fh> };
            close $fh;

            # Strip metadata header
            $expected =~ s/^#.*?\n---\n//s;

            # Normalize both
            my $output_normalized = normalize_output($output, 'debug');
            my $expected_normalized = normalize_output($expected, 'debug');

            # Trim whitespace
            $output_normalized =~ s/^\s+|\s+$//g;
            $expected_normalized =~ s/^\s+|\s+$//g;

            if (matches_pattern($output_normalized, $expected_normalized)) {
                $context_results{debug} = { status => 'PASS', message => '' };
            } else {
                $context_results{debug} = {
                    status => 'FAIL',
                    message => 'Debug output mismatch',
                    expected => $expected_normalized,
                    actual => $output_normalized,
                };
                $any_failures = 1;

                # Debug output for debug context mismatch
                if ($options{verbose} || $ENV{DEBUG_TEST_FAILURES}) {
                    say "  [DEBUG MISMATCH]";
                    say "  Expected:";
                    say "  " . join("\n  ", split /\n/, substr($expected_normalized, 0, 500));
                    say "  Actual:";
                    say "  " . join("\n  ", split /\n/, substr($output_normalized, 0, 500));
                }
            }
        }
        }

        # Store results for this mode
        if ($test_mode eq 'interpreter') {
            %interpreter_results = %context_results;
            $interpreter_failures = $any_failures;
        } else {
            %compiled_results = %context_results;
            $compiled_failures = $any_failures;
        }
    }

    my $duration = time - $start_time;

    # Determine overall status for each mode
    my $interpreter_status = 'N/A';
    my $compiled_status = 'N/A';

    if (grep { $_ eq 'interpreter' } @modes_to_test) {
        $interpreter_status = $interpreter_failures ? 'FAIL' : 'PASS';
        # Check if all contexts were skipped
        my $all_skipped = 1;
        for my $ctx (values %interpreter_results) {
            if ($ctx->{status} ne 'SKIP') {
                $all_skipped = 0;
                last;
            }
        }
        $interpreter_status = 'SKIP' if $all_skipped;
    }

    if (grep { $_ eq 'compiled' } @modes_to_test) {
        $compiled_status = $compiled_failures ? 'FAIL' : 'PASS';
        # Check if all contexts were skipped
        my $all_skipped = 1;
        for my $ctx (values %compiled_results) {
            if ($ctx->{status} ne 'SKIP') {
                $all_skipped = 0;
                last;
            }
        }
        $compiled_status = 'SKIP' if $all_skipped;
    }

    # Overall status
    my $overall_status = 'PASS';
    if ($interpreter_status eq 'FAIL' || $compiled_status eq 'FAIL') {
        $overall_status = 'FAIL';
    } elsif ($interpreter_status eq 'SKIP' && $compiled_status eq 'SKIP') {
        $overall_status = 'SKIP';
    } elsif ($interpreter_status eq 'ERROR' || $compiled_status eq 'ERROR') {
        $overall_status = 'ERROR';
    }

    return {
        name => $example_name,
        type => 'multi-context',
        status => $overall_status,
        duration => $duration,
        contexts => \%interpreter_results,  # For backwards compatibility, show interpreter results
        compiled_contexts => \%compiled_results,
        # For compatibility with existing reporting
        interpreter_status => $interpreter_status,
        compiled_status => $compiled_status,
        interpreter_duration => $duration / scalar(@modes_to_test),
        compiled_duration => $duration / scalar(@modes_to_test),
        build_duration => 0,
        avg_duration => $duration / scalar(@modes_to_test),
    };
}
1;
