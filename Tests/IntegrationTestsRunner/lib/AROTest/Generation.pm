package AROTest::Generation;

# `--generate` mode: capture an example's output once and persist it as the
# new expected.txt, with auto-placeholderisation for dynamic values (IDs,
# UUIDs, timestamps). Multi-context examples get three expected-*.txt files
# instead of one. Pre-existing files are overwritten.

use strict;
use warnings;
use v5.30;
use File::Spec;
use Time::HiRes qw(sleep);
use Exporter 'import';

use AROTest::Utils qw($is_windows $is_linux $is_macos colored);
use AROTest::Config qw(%options $examples_dir);
use AROTest::Hint qw(read_test_hint);
use AROTest::Detect qw(detect_example_type);
use AROTest::Normalize qw(normalize_output);
use AROTest::Match qw(auto_placeholderize);
use AROTest::Runner qw(run_test_in_workdir);
use AROTest::Executor::Console qw(run_console_example_internal run_debug_example);
use AROTest::Executor::HTTP qw(run_http_example_internal);

our @EXPORT_OK = qw(generate_expected generate_all_expected);

sub generate_expected {
    my ($example_name) = @_;

    # Read test hints
    my $hints = read_test_hint($example_name);

    # Skip if requested
    if (defined $hints->{skip}) {
        say "Skipping $example_name: $hints->{skip}";
        return;
    }

    # Skip on Windows if requested
    if ($is_windows && defined $hints->{'skip-on-windows'}) {
        say "Skipping $example_name on Windows: $hints->{'skip-on-windows'}";
        return;
    }

    # Skip on Linux if requested
    if ($is_linux && defined $hints->{'skip-on-linux'}) {
        say "Skipping $example_name on Linux: $hints->{'skip-on-linux'}";
        return;
    }

    # Skip on macOS if requested
    if ($is_macos && defined $hints->{'skip-on-macos'}) {
        say "Skipping $example_name on macOS: $hints->{'skip-on-macos'}";
        return;
    }

    # Use type from hints or auto-detect
    my $type = $hints->{type} || detect_example_type($example_name);

    # Use timeout from hints or default
    my $timeout = $hints->{timeout} // $options{timeout};

    say "Generating expected output for $example_name ($type)...";

    # Handle multi-context generation
    if ($type eq 'multi-context') {
        # Generate console output
        my $exp_console = File::Spec->catfile($examples_dir, $example_name, 'expected-console.txt');
        say "  Generating console context...";
        my ($console_out, $console_err) = run_console_example_internal($example_name, $timeout, 'interpreter', undef, $hints);
        if ($console_err) {
            warn colored("  ✗ Failed (console): $console_err\n", 'red');
        } else {
            my $output = normalize_output($console_out, 'console');
            $output = auto_placeholderize($output, 'console');
            open my $fh, '>', $exp_console or die "Cannot write $exp_console: $!";
            print $fh "# Generated: " . localtime() . "\n";
            print $fh "# Type: console\n";
            print $fh "# Command: aro run ./Examples/$example_name\n";
            print $fh "---\n";
            print $fh $output;
            close $fh;
            say colored("  ✓ Generated $exp_console", 'green');
        }

        # Generate HTTP output
        my $exp_http = File::Spec->catfile($examples_dir, $example_name, 'expected-http.txt');
        say "  Generating HTTP context...";
        my ($http_out, $http_err) = run_http_example_internal($example_name, $timeout, 'interpreter', undef);
        if ($http_err) {
            warn colored("  ✗ Failed (HTTP): $http_err\n", 'red');
        } else {
            my $output = normalize_output($http_out, 'http');
            $output = auto_placeholderize($output, 'http');
            open my $fh, '>', $exp_http or die "Cannot write $exp_http: $!";
            print $fh "# Generated: " . localtime() . "\n";
            print $fh "# Type: http\n";
            print $fh "# Command: HTTP GET /demo\n";
            print $fh "---\n";
            print $fh $output;
            close $fh;
            say colored("  ✓ Generated $exp_http", 'green');
        }

        # Generate debug output
        my $exp_debug = File::Spec->catfile($examples_dir, $example_name, 'expected-debug.txt');
        say "  Generating debug context...";
        my ($debug_out, $debug_err) = run_debug_example($example_name, $timeout, 'interpreter', undef, $hints);
        if ($debug_err) {
            warn colored("  ✗ Failed (debug): $debug_err\n", 'red');
        } else {
            my $output = normalize_output($debug_out, 'debug');
            $output = auto_placeholderize($output, 'debug');
            open my $fh, '>', $exp_debug or die "Cannot write $exp_debug: $!";
            print $fh "# Generated: " . localtime() . "\n";
            print $fh "# Type: debug\n";
            print $fh "# Command: aro run ./Examples/$example_name --debug\n";
            print $fh "---\n";
            print $fh $output;
            close $fh;
            say colored("  ✓ Generated $exp_debug\n", 'green');
        }

        return;
    }

    # Regular single-context generation
    my $expected_file = File::Spec->catfile($examples_dir, $example_name, 'expected.txt');

    # Execute with workdir and pre-script support
    my ($output, $error) = run_test_in_workdir(
        $example_name,
        $hints->{workdir},
        $timeout,
        $type,
        $hints->{'pre-script'},
        'interpreter',
        $hints
    );

    if ($error) {
        warn colored("  ✗ Failed: $error\n", 'red');
        return;
    }

    # Normalize output before saving
    $output = normalize_output($output, $type);

    # Auto-replace dynamic values with placeholders
    $output = auto_placeholderize($output, $type);

    # Write with enhanced metadata header
    open my $fh, '>', $expected_file or die "Cannot write $expected_file: $!";
    print $fh "# Generated: " . localtime() . "\n";
    print $fh "# Type: $type\n";
    print $fh "# Command: aro run ./Examples/$example_name\n";

    # Add note if test-script is used (output not used for verification)
    if (defined $hints->{'test-script'}) {
        print $fh "# NOTE: This example uses test-script for verification\n";
        print $fh "# This expected.txt is for reference only, not used in testing\n";
    }

    # Add optional metadata from hints
    if (defined $hints->{workdir}) {
        print $fh "# Workdir: $hints->{workdir}\n";
    }

    if (defined $hints->{timeout} && $hints->{timeout} != $options{timeout}) {
        print $fh "# Timeout: $hints->{timeout}s\n";
    }

    print $fh "---\n";
    print $fh $output;
    close $fh;

    say colored("  ✓ Generated $expected_file\n", 'green');
}

# Generate all expected outputs
sub generate_all_expected {
    my ($examples) = @_;

    my $total = scalar @$examples;
    my $current = 0;

    for my $example (@$examples) {
        $current++;
        say sprintf("[%d/%d] %s", $current, $total, $example);

        eval {
            generate_expected($example);
        };
        if ($@) {
            warn colored("  ✗ Error: $@\n", 'red');
        }

        # Prevent overwhelming the system
        sleep 0.5;
    }

    say "\nGeneration complete. $current expected files created/updated.";
}
1;
