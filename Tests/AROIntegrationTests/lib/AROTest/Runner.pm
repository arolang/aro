package AROTest::Runner;

use strict;
use warnings;
use v5.30;
use File::Spec;
use Time::HiRes qw(time);
use Cwd qw(cwd);

use AROTest::Discovery qw(read_test_hint);
use AROTest::TypeDetection qw(detect_type);
use AROTest::Executor::Console;
use AROTest::Executor::HTTP;
use AROTest::Executor::Socket;
use AROTest::Executor::FileWatcher;
use AROTest::Binary::Execution qw(build_binary execute_binary);
use AROTest::Comparison::Normalization qw(normalize_feature_prefix);
use AROTest::Comparison::Matching qw(matches_pattern);

=head1 NAME

AROTest::Runner - Main test orchestration for ARO integration tests

=head1 SYNOPSIS

    use AROTest::Runner;

    my $runner = AROTest::Runner->new($config);
    my $result = $runner->run_test('HelloWorld');
    my @results = $runner->run_all_tests(@example_names);

=head1 DESCRIPTION

Orchestrates test execution for ARO examples. Handles both interpreter
(aro run) and compiled binary (aro build) testing phases.

=cut

=head2 new($config)

Create a new test runner.

Parameters:

=over 4

=item * C<$config> - AROTest::Config instance

=back

=cut

sub new {
    my ($class, $config) = @_;

    my $self = bless {
        config => $config,
        executors => {
            console => AROTest::Executor::Console->new($config),
            http => AROTest::Executor::HTTP->new($config),
            socket => AROTest::Executor::Socket->new($config),
            file => AROTest::Executor::FileWatcher->new($config),
        },
    }, $class;

    return $self;
}

=head2 run_test($example_name)

Run a single test with both run and build phases.

Parameters:

=over 4

=item * C<$example_name> - Name of the example to test

=back

Returns: Hash reference with test results

=cut

sub run_test {
    my ($self, $example_name) = @_;

    my $config = $self->{config};
    my $examples_dir = $config->examples_dir;
    my $dir = File::Spec->catdir($examples_dir, $example_name);

    # Delete old diff files
    my $run_diff_file = File::Spec->catfile($dir, 'expected.run.diff');
    my $build_diff_file = File::Spec->catfile($dir, 'expected.build.diff');
    unlink $run_diff_file if -f $run_diff_file;
    unlink $build_diff_file if -f $build_diff_file;

    # Read test hints
    my $hints = read_test_hint($dir, $config);

    # Handle skip directive
    if (defined $hints->{skip}) {
        return {
            name => $example_name,
            type => 'UNKNOWN',
            run_status => 'SKIP',
            build_status => 'SKIP',
            run_message => "Skipped: $hints->{skip}",
            build_message => "Skipped",
            run_duration => 0,
            build_duration => 0,
            total_duration => 0,
        };
    }

    # Determine type and timeout
    my $type = $hints->{type} || detect_type($dir);
    my $timeout = $hints->{timeout} // $config->timeout;

    say "Testing $example_name ($type)..." if $config->is_verbose;

    # Read expected output
    my $expected_file = File::Spec->catfile($dir, 'expected.txt');
    my $expected = $self->_read_expected_file($expected_file);

    # Phase 1: Interpreter Run
    my ($run_status, $run_message, $run_duration, $run_actual, $run_expected) =
        $self->_run_interpreter_phase($example_name, $dir, $type, $timeout, $expected, $expected_file, $hints);

    # Phase 2: Binary Build & Run (only if run phase passed)
    my ($build_status, $build_message, $build_duration, $build_actual, $build_expected) =
        ('SKIP', 'Not tested', 0, '', '');

    if ($run_status eq 'PASS' && !$hints->{'skip-build'}) {
        ($build_status, $build_message, $build_duration, $build_actual, $build_expected) =
            $self->_run_binary_phase($example_name, $dir, $type, $timeout, $expected);
    }

    return {
        name => $example_name,
        type => $type,
        run_status => $run_status,
        build_status => $build_status,
        run_message => $run_message,
        build_message => $build_message,
        run_duration => $run_duration,
        build_duration => $build_duration,
        total_duration => $run_duration + $build_duration,
        expected_file => $expected_file,
        run_expected => $run_expected,
        run_actual => $run_actual,
        build_expected => $build_expected,
        build_actual => $build_actual,
    };
}

=head2 run_all_tests(@example_names)

Run tests for multiple examples.

Parameters:

=over 4

=item * C<@example_names> - List of example names to test

=back

Returns: Array of test result hashes

=cut

sub run_all_tests {
    my ($self, @example_names) = @_;

    my @results;
    my $total = scalar @example_names;
    my $current = 0;

    for my $example (@example_names) {
        $current++;
        unless ($self->{config}->is_verbose) {
            print sprintf("[%d/%d] %s... ", $current, $total, $example);
        }

        my $result = $self->run_test($example);
        push @results, $result;

        unless ($self->{config}->is_verbose) {
            require AROTest::Reporting;
            print "Run: " . AROTest::Reporting::colored_status($result->{run_status}) .
                  " Build: " . AROTest::Reporting::colored_status($result->{build_status}) . "\n";

            # Show error messages
            $self->_print_error_message('Run', $result->{run_status}, $result->{run_message});
            $self->_print_error_message('Build', $result->{build_status}, $result->{build_message});
        }
    }

    return @results;
}

# Read expected output file
sub _read_expected_file {
    my ($self, $expected_file) = @_;

    my $expected = '';
    if (-f $expected_file) {
        open my $fh, '<', $expected_file or die "Cannot read $expected_file: $!";
        $expected = do { local $/; <$fh> };
        close $fh;
        $expected =~ s/^#.*?\n---\n//s;  # Strip metadata
    }
    return $expected;
}

# Run interpreter phase
sub _run_interpreter_phase {
    my ($self, $example_name, $dir, $type, $timeout, $expected, $expected_file, $hints) = @_;

    my $run_start = time;
    my ($run_output, $run_error);

    # Get the appropriate executor
    my $executor = $self->{executors}{$type};
    unless ($executor) {
        return ('ERROR', "Unknown test type: $type", 0, '', '');
    }

    # Handle working directory if specified
    if ($hints->{workdir}) {
        my $orig_cwd = cwd();
        my $workdir = File::Spec->rel2abs($hints->{workdir});

        unless (chdir $workdir) {
            return ('ERROR', "Cannot change to workdir: $workdir", 0, '', '');
        }

        ($run_output, $run_error) = $executor->execute('.', $timeout, $hints);
        chdir $orig_cwd;
    } else {
        ($run_output, $run_error) = $executor->execute($dir, $timeout, $hints);
    }

    my $run_duration = time - $run_start;

    # Determine status
    my ($run_status, $run_message, $run_actual, $run_expected) = ('ERROR', '', '', '');

    if (defined $run_error && $run_error =~ /^SKIP/) {
        $run_status = 'SKIP';
        $run_message = $run_error;
    } elsif (defined $run_error) {
        $run_status = 'ERROR';
        $run_message = $run_error;
    } elsif (!-f $expected_file) {
        $run_status = 'SKIP';
        $run_message = 'No expected output file';
    } else {
        # Compare with expected
        my $output_trimmed = normalize_feature_prefix($run_output);
        my $expected_trimmed = normalize_feature_prefix($expected);

        $output_trimmed =~ s/^\s+|\s+$//g;
        $output_trimmed =~ s/ +$//gm;
        $expected_trimmed =~ s/^\s+|\s+$//g;
        $expected_trimmed =~ s/ +$//gm;

        my $matched;
        if ($hints && $hints->{'occurrence-check'}) {
            # Occurrence-based matching: each expected line must appear somewhere
            require AROTest::Comparison::Matching;
            my ($success, $missing) = AROTest::Comparison::Matching::check_occurrences($output_trimmed, $expected_trimmed);
            $matched = $success;
        } else {
            $matched = matches_pattern($output_trimmed, $expected_trimmed);
        }

        if ($matched) {
            $run_status = 'PASS';
            say "  Run phase: PASS" if $self->{config}->is_verbose;
        } else {
            $run_status = 'FAIL';
            $run_message = "Output mismatch";
            $run_actual = $output_trimmed;
            $run_expected = $expected_trimmed;
            say "  Run phase: FAIL" if $self->{config}->is_verbose;
        }
    }

    return ($run_status, $run_message, $run_duration, $run_actual, $run_expected);
}

# Run binary phase
sub _run_binary_phase {
    my ($self, $example_name, $dir, $type, $timeout, $expected) = @_;

    say "  Starting build phase..." if $self->{config}->is_verbose;

    # Build binary
    my ($binary, $build_error, $build_time) = build_binary($example_name, $dir);

    if ($build_error) {
        say "  Build phase: ERROR - $build_error" if $self->{config}->is_verbose;
        return ('ERROR', $build_error, $build_time, '', '');
    }

    # Execute binary
    my ($build_output, $exec_error, $exec_time) = execute_binary($binary, $type, $timeout, $self->{config});
    my $total_time = $build_time + $exec_time;

    if ($exec_error) {
        say "  Build phase: ERROR - $exec_error" if $self->{config}->is_verbose;
        return ('ERROR', $exec_error, $total_time, '', '');
    }

    # Compare with expected
    my $output_trimmed = normalize_feature_prefix($build_output);
    my $expected_trimmed = normalize_feature_prefix($expected);

    $output_trimmed =~ s/^\s+|\s+$//g;
    $output_trimmed =~ s/ +$//gm;
    $expected_trimmed =~ s/^\s+|\s+$//g;
    $expected_trimmed =~ s/ +$//gm;

    if (matches_pattern($output_trimmed, $expected_trimmed)) {
        say "  Build phase: PASS" if $self->{config}->is_verbose;
        return ('PASS', '', $total_time, '', '');
    } else {
        say "  Build phase: FAIL" if $self->{config}->is_verbose;
        return ('FAIL', "Output mismatch", $total_time, $output_trimmed, $expected_trimmed);
    }
}

# Print error message if present
sub _print_error_message {
    my ($self, $phase, $status, $message) = @_;

    return unless ($status eq 'FAIL' || $status eq 'ERROR');
    return unless $message;

    require AROTest::Utils;
    my $msg = $message;
    if (length($msg) > 100) {
        $msg = (split /\n/, $msg)[0];
        $msg = substr($msg, 0, 97) . "..." if length($msg) > 100;
    }
    print "  $phase error: " . AROTest::Utils::colored($msg, 'red') . "\n";
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
