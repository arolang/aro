package AROTest::Runner;

# Top-level test orchestration: dispatching each example to the right
# executor, running a single mode (interpreter or compiled), running both
# modes back-to-back for a "full" test result, and looping over the example
# set with serial or parallel execution. Verdicts and per-example diffs
# fall out the bottom.

use strict;
use warnings;
use v5.30;
use File::Spec;
use File::Basename;
use Cwd qw(cwd);
use Time::HiRes qw(time);
use List::Util qw(sum all);
use Exporter 'import';

use AROTest::Utils qw($is_windows $is_linux $is_macos $is_ci colored);
use AROTest::Config qw(%options %results $examples_dir $project_root);
use AROTest::Hint qw(read_test_hint write_testrun_log);
use AROTest::Detect qw(detect_example_type);
use AROTest::Binary qw(find_aro_binary build_example);
use AROTest::Shell qw(run_script);
use AROTest::Normalize qw(normalize_output normalize_dict_literals);
use AROTest::Match qw(matches_pattern check_output_occurrences);
use AROTest::Reporting qw(print_summary create_diff_file _emit_result_line);
use AROTest::Pool qw(run_pool requires_serial_run);
use AROTest::Executor::Console qw(run_console_example_internal);
use AROTest::Executor::HTTP qw(run_http_example_internal);
use AROTest::Executor::Socket qw(run_socket_example_internal run_socket_client_example_internal);
use AROTest::Executor::FileWatcher qw(run_file_watcher_example_internal);
use AROTest::Executor::MultiService qw(run_multiservice_example_internal);
use AROTest::Executor::MultiContext qw(test_multi_context_example);

our @EXPORT_OK = qw(run_test_in_workdir run_single_mode_test run_test run_all_tests);

sub run_test_in_workdir {
    my ($example_name, $workdir, $timeout, $type, $pre_script, $mode, $hints) = @_;
    $mode //= 'interpreter';  # Default to interpreter mode

    my $orig_cwd = cwd();
    my $output;
    my $error;
    my $run_dir = $example_name;  # Default: use example name as-is
    my $binary_name;  # For compiled mode when using workdir

    # Change directory if specified
    if (defined $workdir) {
        # Convert relative path to absolute (relative to project root)
        my $abs_workdir = $workdir;
        unless (File::Spec->file_name_is_absolute($workdir)) {
            $abs_workdir = File::Spec->catdir($project_root, $workdir);
        }

        unless (-d $abs_workdir) {
            return (undef, "ERROR: workdir does not exist: $abs_workdir");
        }

        unless (chdir $abs_workdir) {
            return (undef, "ERROR: Cannot change to workdir $abs_workdir: $!");
        }

        say "  Changed to workdir: $abs_workdir" if $options{verbose};

        # When running from workdir, use current directory
        $run_dir = '.';
        # Use workdir's directory name for finding compiled binary (e.g., Combined from Examples/ModulesExample/Combined)
        $binary_name = basename($abs_workdir);
    }

    # Execute pre-script if specified
    if (defined $pre_script) {
        say "  Running pre-script: $pre_script" if $options{verbose};
        my ($out, $err, $exit_code) = run_script($pre_script, $timeout, "pre-script");

        if ($exit_code != 0) {
            unless (chdir $orig_cwd) {
                warn "WARNING: Cannot restore directory $orig_cwd: $!\n";
            }
            return (undef, "Pre-script failed (exit $exit_code): $err");
        }

        say "  Pre-script output: $out" if $options{verbose} && $out;
    }

    # Execute with current timeout based on type
    # Pass $run_dir instead of $example_name to the internal functions
    # Pass $binary_name for compiled mode when using workdir
    if ($type eq 'console') {
        ($output, $error) = run_console_example_internal($run_dir, $timeout, $mode, $binary_name, $hints);
    } elsif ($type eq 'http') {
        ($output, $error) = run_http_example_internal($run_dir, $timeout, $mode, $binary_name, $hints);
    } elsif ($type eq 'socket') {
        ($output, $error) = run_socket_example_internal($run_dir, $timeout, $mode, $binary_name);
    } elsif ($type eq 'socket-client') {
        ($output, $error) = run_socket_client_example_internal($run_dir, $timeout, $mode, $binary_name);
    } elsif ($type eq 'file') {
        ($output, $error) = run_file_watcher_example_internal($run_dir, $timeout, $mode, $binary_name);
    } elsif ($type eq 'multiservice') {
        ($output, $error) = run_multiservice_example_internal($run_dir, $timeout, $mode, $binary_name);
    }

    # Restore original directory
    unless (chdir $orig_cwd) {
        warn "WARNING: Cannot restore directory $orig_cwd: $!\n";
    }

    return ($output, $error);
}

sub run_single_mode_test {
    my ($example_name, $hints, $type, $timeout, $mode) = @_;

    my $start_time = time;

    say "  Testing $example_name in $mode mode..." if $options{verbose};

    # Execute with workdir and pre-script support
    my ($output, $error) = run_test_in_workdir(
        $example_name,
        $hints->{workdir},
        $timeout,
        $type,
        $hints->{'pre-script'},
        $mode,
        $hints
    );

    my $duration = time - $start_time;

    if ($error) {
        # Log execution errors (not skips)
        unless ($error =~ /^SKIP/) {
            my $error_type = $error =~ /TIMEOUT/ ? 'TIMEOUT' :
                            $error =~ /Exit code/ ? 'EXECUTION_FAILURE' : 'ERROR';
            write_testrun_log($example_name, $mode, $error_type, $error, undef, undef);
        }
        return {
            name => $example_name,
            type => $type,
            status => $error =~ /^SKIP/ ? 'SKIP' : 'ERROR',
            message => $error,
            duration => $duration,
        };
    }

    # If test-script is defined, use it instead of output comparison
    if (defined $hints->{'test-script'}) {
        say "  Running test-script: $hints->{'test-script'}" if $options{verbose};

        # Need to be in workdir for test-script
        my $orig_cwd = cwd();
        if (defined $hints->{workdir}) {
            my $abs_workdir = File::Spec->file_name_is_absolute($hints->{workdir})
                ? $hints->{workdir}
                : File::Spec->catdir($project_root, $hints->{workdir});
            chdir $abs_workdir if -d $abs_workdir;
        }

        # Set ARO_BIN environment variable for test-script to use
        my $aro_bin = find_aro_binary();
        local $ENV{ARO_BIN} = $aro_bin;

        my ($test_out, $test_err, $exit_code) = run_script(
            $hints->{'test-script'},
            $timeout,
            "test-script"
        );

        chdir $orig_cwd;

        if ($exit_code == 0) {
            say "  Test script passed" if $options{verbose};
            return {
                name => $example_name,
                type => $type,
                status => 'PASS',
                message => '',
                duration => $duration,
            };
        } else {
            my $error_msg = "Test script failed (exit $exit_code)" . ($test_err ? ": $test_err" : "");
            write_testrun_log($example_name, $mode, 'TEST_SCRIPT_FAILURE', $error_msg, $hints->{'test-script'}, $exit_code);
            return {
                name => $example_name,
                type => $type,
                status => 'FAIL',
                message => $error_msg,
                duration => $duration,
                actual => $test_err,
            };
        }
    }

    # Compare with expected output
    # Find the most specific expected file based on platform and mode
    my $platform = $^O;  # 'linux', 'darwin', 'MSWin32', etc.
    $platform = 'linux' if $platform eq 'linux';
    $platform = 'macos' if $platform eq 'darwin';
    $platform = 'windows' if $platform =~ /^MSWin/;

    my @expected_candidates = (
        "expected.$platform-$mode.txt",    # e.g., expected.linux-compiled.txt
        "expected.$platform.txt",           # e.g., expected.linux.txt
        "expected.$mode.txt",               # e.g., expected.compiled.txt
        "expected.txt",                     # fallback
    );

    my $expected_file;
    for my $candidate (@expected_candidates) {
        my $path = File::Spec->catfile($examples_dir, $example_name, $candidate);
        if (-f $path) {
            $expected_file = $path;
            last;
        }
    }

    unless ($expected_file) {
        return {
            name => $example_name,
            type => $type,
            status => 'SKIP',
            message => 'No expected output file (run with --generate)',
            duration => $duration,
        };
    }

    # Read expected output
    open my $fh, '<', $expected_file or die "Cannot read $expected_file: $!";
    my $expected = do { local $/; <$fh> };
    close $fh;

    # Strip metadata header
    $expected =~ s/^#.*?\n---\n//s;

    # Trim whitespace from both (without other normalization for pattern matching)
    my $output_for_comparison = $output;
    my $expected_for_comparison = $expected;
    $output_for_comparison =~ s/^\s+|\s+$//g;
    $output_for_comparison =~ s/ +$//gm;  # Remove trailing spaces from lines
    $expected_for_comparison =~ s/^\s+|\s+$//g;
    $expected_for_comparison =~ s/ +$//gm;

    # Choose validation method based on occurrence-check directive
    if (defined $hints->{'occurrence-check'} && $hints->{'occurrence-check'} eq 'true') {
        # Use occurrence-based validation (order-independent)
        # For occurrence check, we need normalized output
        my $output_normalized = normalize_output($output, $type);
        my $expected_normalized = normalize_output($expected, $type);

        # Apply dictionary key sorting if normalize-dict hint is set
        if (defined $hints->{'normalize-dict'} && $hints->{'normalize-dict'} eq 'true') {
            $output_normalized = normalize_dict_literals($output_normalized);
            $expected_normalized = normalize_dict_literals($expected_normalized);
        }

        my ($all_found, $missing_ref) = check_output_occurrences($output_normalized, $expected_normalized);

        if ($all_found) {
            say "  All expected output lines found (order-independent)" if $options{verbose};
            return {
                name => $example_name,
                type => $type,
                status => 'PASS',
                message => '',
                duration => $duration,
            };
        } else {
            my @missing = @$missing_ref;
            # Always print missing lines and actual output on Linux for diagnosis
            if ($is_linux) {
                say "  [Linux Debug] Missing lines:";
                for my $line (@missing) {
                    say "    - $line";
                }
                say "  [Linux Debug] Actual output:";
                for my $line (split /\n/, $output_normalized) {
                    say "    | $line";
                }
            }
            my $diff = '';
            if ($options{verbose}) {
                $diff = "\nExpected:\n$expected_normalized\n\nActual:\n$output_normalized\n";
            }
            my $error_msg = "Missing " . scalar(@missing) . " expected line(s)$diff";
            my $full_error = $error_msg . "\nMissing lines:\n" . join("\n", map { "  - $_" } @missing);
            write_testrun_log($example_name, $mode, 'OUTPUT_MISMATCH', $full_error, undef, undef);
            return {
                name => $example_name,
                type => $type,
                status => 'FAIL',
                message => $error_msg,
                duration => $duration,
                expected => $expected_normalized,
                actual => $output_normalized,
                diff => "Missing lines:\n" . join("\n", map { "  - $_" } @missing),
            };
        }
    } else {
        # Use pattern matching for comparison (supports __ID__, __UUID__, etc.)
        # Normalize both to remove brackets and other dynamic content
        my $output_normalized = normalize_output($output, $type);
        my $expected_normalized = normalize_output($expected, $type);

        # Apply dictionary key sorting if normalize-dict hint is set
        if (defined $hints->{'normalize-dict'} && $hints->{'normalize-dict'} eq 'true') {
            $output_normalized = normalize_dict_literals($output_normalized);
            $expected_normalized = normalize_dict_literals($expected_normalized);
        }

        # Trim whitespace after normalization
        $output_normalized =~ s/^\s+|\s+$//g;
        $output_normalized =~ s/ +$//gm;
        $expected_normalized =~ s/^\s+|\s+$//g;
        $expected_normalized =~ s/ +$//gm;

        if (matches_pattern($output_normalized, $expected_normalized)) {
            return {
                name => $example_name,
                type => $type,
                status => 'PASS',
                message => '',
                duration => $duration,
            };
        } else {
            # Always print output mismatch details on Linux for diagnosis
            if ($is_linux) {
                say "  [Linux Debug] Output mismatch - expected:";
                for my $line (split /\n/, $expected_normalized) {
                    say "    E| $line";
                }
                say "  [Linux Debug] Actual:";
                for my $line (split /\n/, $output_normalized) {
                    say "    A| $line";
                }
            }
            my $diff = '';
            if ($options{verbose}) {
                $diff = "\nExpected:\n$expected_normalized\n\nActual:\n$output_normalized\n";
            }
            my $error_msg = "Output mismatch$diff";
            write_testrun_log($example_name, $mode, 'OUTPUT_MISMATCH', $error_msg, undef, undef);
            return {
                name => $example_name,
                type => $type,
                status => 'FAIL',
                message => $error_msg,
                duration => $duration,
                expected => $expected_normalized,
                actual => $output_normalized,
                expected_file => $expected_file,
            };
        }
    }
}

# Run test for a single example (dual-mode orchestration)
sub run_test {
    my ($example_name) = @_;

    # Delete old diff files and testrun.log if they exist
    my $diff_file = "Examples/$example_name/expected.diff";
    my $binary_diff_file = "Examples/$example_name/expected.binary.diff";
    my $log_file = "Examples/$example_name/testrun.log";
    unlink $diff_file if -f $diff_file;
    unlink $binary_diff_file if -f $binary_diff_file;
    unlink $log_file if -f $log_file;

    # Read test hints
    my $hints = read_test_hint($example_name);

    # Handle skip directive (applies to both modes)
    if (defined $hints->{skip}) {
        return {
            name => $example_name,
            type => 'UNKNOWN',
            interpreter_status => 'SKIP',
            compiled_status => 'SKIP',
            interpreter_message => "Skipped: $hints->{skip}",
            compiled_message => "Skipped: $hints->{skip}",
            interpreter_duration => 0,
            compiled_duration => 0,
            build_duration => 0,
            avg_duration => 0,
            status => 'SKIP',
            duration => 0,
        };
    }

    # Handle Windows-specific skip
    if ($is_windows && defined $hints->{'skip-on-windows'}) {
        return {
            name => $example_name,
            type => 'UNKNOWN',
            interpreter_status => 'SKIP',
            compiled_status => 'SKIP',
            interpreter_message => "Skipped on Windows: $hints->{'skip-on-windows'}",
            compiled_message => "Skipped on Windows: $hints->{'skip-on-windows'}",
            interpreter_duration => 0,
            compiled_duration => 0,
            build_duration => 0,
            avg_duration => 0,
            status => 'SKIP',
            duration => 0,
        };
    }

    # Handle Linux-specific skip
    if ($is_linux && defined $hints->{'skip-on-linux'}) {
        return {
            name => $example_name,
            type => 'UNKNOWN',
            interpreter_status => 'SKIP',
            compiled_status => 'SKIP',
            interpreter_message => "Skipped on Linux: $hints->{'skip-on-linux'}",
            compiled_message => "Skipped on Linux: $hints->{'skip-on-linux'}",
            interpreter_duration => 0,
            compiled_duration => 0,
            build_duration => 0,
            avg_duration => 0,
            status => 'SKIP',
            duration => 0,
        };
    }

    # Handle macOS-specific skip
    if ($is_macos && defined $hints->{'skip-on-macos'}) {
        return {
            name => $example_name,
            type => 'UNKNOWN',
            interpreter_status => 'SKIP',
            compiled_status => 'SKIP',
            interpreter_message => "Skipped on macOS: $hints->{'skip-on-macos'}",
            compiled_message => "Skipped on macOS: $hints->{'skip-on-macos'}",
            interpreter_duration => 0,
            compiled_duration => 0,
            build_duration => 0,
            avg_duration => 0,
            status => 'SKIP',
            duration => 0,
        };
    }

    # Handle CI-specific skip — used for examples that depend on
    # unreliable external services (e.g. URLClient hits
    # jsonplaceholder.typicode.com and httpbin.org). Local devs still
    # run the test; CI runners get a deterministic SKIP.
    if ($is_ci && defined $hints->{'skip-on-ci'}) {
        return {
            name => $example_name,
            type => 'UNKNOWN',
            interpreter_status => 'SKIP',
            compiled_status => 'SKIP',
            interpreter_message => "Skipped on CI: $hints->{'skip-on-ci'}",
            compiled_message => "Skipped on CI: $hints->{'skip-on-ci'}",
            interpreter_duration => 0,
            compiled_duration => 0,
            build_duration => 0,
            avg_duration => 0,
            status => 'SKIP',
            duration => 0,
        };
    }

    # Determine test mode
    my $mode = $hints->{mode} // 'both';
    my $type = $hints->{type} || detect_example_type($example_name);
    my $timeout = $hints->{timeout} // $options{timeout};

    # Handle multi-context testing separately
    if ($type eq 'multi-context') {
        return test_multi_context_example($example_name, $hints, $timeout);
    }

    say "Testing $example_name ($type) in $mode mode..." if $options{verbose};

    # Initialize result
    my $result = {
        name => $example_name,
        type => $type,
        interpreter_status => 'N/A',
        compiled_status => 'N/A',
        interpreter_message => '',
        compiled_message => '',
        interpreter_duration => 0,
        compiled_duration => 0,
        build_duration => 0,
        avg_duration => 0,
    };

    # Run interpreter test
    if ($mode eq 'interpreter' || $mode eq 'both' || $mode eq 'test') {
        my $test_mode = $mode eq 'test' ? 'test' : 'interpreter';
        my $interp_result = run_single_mode_test(
            $example_name, $hints, $type, $timeout, $test_mode
        );

        $result->{interpreter_status} = $interp_result->{status};
        $result->{interpreter_duration} = $interp_result->{duration};
        $result->{interpreter_message} = $interp_result->{message} // '';
        $result->{interpreter_expected} = $interp_result->{expected};
        $result->{interpreter_actual} = $interp_result->{actual};
    }

    # Run compiled test
    # Skip build if hint says so (e.g., keep-alive tests that don't support compiled mode)
    if ($hints->{'skip-build'} && ($mode eq 'compiled' || $mode eq 'both')) {
        $result->{compiled_status} = 'SKIP';
        $result->{compiled_message} = 'Skipped by skip-build hint';
        $result->{compiled_duration} = 0;
        $result->{build_duration} = 0;
    # Note: Native compilation (aro build) is not supported on Windows yet
    } elsif ($is_windows && ($mode eq 'compiled' || $mode eq 'both')) {
        $result->{compiled_status} = 'SKIP';
        $result->{compiled_message} = 'Native compilation not supported on Windows';
        $result->{compiled_duration} = 0;
        $result->{build_duration} = 0;
    } elsif ($mode eq 'compiled' || $mode eq 'both') {
        # Build the example first (use workdir if specified)
        # Use global timeout for build (not hints timeout) - hints timeout may be very short
        # for keep-alive examples (e.g. 3s) which would cause builds to time out on slow CI machines
        my $build_result = build_example($example_name, $options{timeout}, $hints->{workdir});
        $result->{build_duration} = $build_result->{duration};

        if (!$build_result->{success}) {
            # Build failed - mark as ERROR
            $result->{compiled_status} = 'ERROR';
            $result->{compiled_message} = $build_result->{error};
            $result->{compiled_duration} = 0;
        } else {
            # Build succeeded - run compiled test
            my $compiled_result = run_single_mode_test(
                $example_name, $hints, $type, $timeout, 'compiled'
            );

            $result->{compiled_status} = $compiled_result->{status};
            $result->{compiled_duration} = $compiled_result->{duration};
            $result->{compiled_message} = $compiled_result->{message} // '';
            $result->{compiled_expected} = $compiled_result->{expected};
            $result->{compiled_actual} = $compiled_result->{actual};
        }
    }

    # Calculate averages and overall status
    my @durations = grep { $_ > 0 } (
        $result->{interpreter_duration},
        $result->{compiled_duration}
    );
    $result->{avg_duration} = @durations ? (sum(@durations) / @durations) : 0;

    # Overall status: PASS only if both tested modes passed
    my @statuses = grep { $_ ne 'N/A' } (
        $result->{interpreter_status},
        $result->{compiled_status}
    );

    if (grep { $_ eq 'FAIL' || $_ eq 'ERROR' } @statuses) {
        $result->{status} = 'FAIL';
    } elsif ($result->{compiled_status} eq 'SKIP' && $result->{interpreter_status} eq 'PASS') {
        # If interpreter passes but compiled is skipped (Windows, skip-build, etc.), overall is PASS
        $result->{status} = 'PASS';
    } elsif (grep { $_ eq 'SKIP' } @statuses) {
        $result->{status} = 'SKIP';
    } elsif (@statuses > 0 && all { $_ eq 'PASS' } @statuses) {
        $result->{status} = 'PASS';
    } else {
        $result->{status} = 'ERROR';
    }

    $result->{duration} = $result->{avg_duration};

    return $result;
}
sub run_all_tests {
    my ($examples) = @_;

    my $total = scalar @$examples;
    my @results;

    my $start_time = time;

    if ($options{jobs} > 1 && $total > 1) {
        # Split into parallel-safe and serial-must groups.
        my (@parallel, @serial);
        for my $name (@$examples) {
            if (AROTest::Pool::requires_serial_run($name)) {
                push @serial, $name;
            } else {
                push @parallel, $name;
            }
        }

        push @results, AROTest::Pool::run_pool(\@parallel, $options{jobs}, $total, 0, \&run_test)
            if @parallel;
        push @results, AROTest::Pool::run_pool(\@serial, 1, $total, scalar @parallel, \&run_test)
            if @serial;

        # Flake retry: re-run failed tests serially. Most parallel-mode
        # failures are port-allocation races between HTTP tests
        # (Net::EmptyPort probes the port without holding it). A few
        # tests — notably RepositoryObserver on macOS — flake under
        # generic CPU contention because observer Tasks drop a log
        # line. We retry up to twice serially; a real failure won't
        # recover from three attempts but a flake almost always will.
        my $max_attempts = 3;  # initial + 2 serial retries
        for my $attempt (2 .. $max_attempts) {
            my @to_retry = grep {
                $_->{status} eq 'FAIL' || $_->{status} eq 'ERROR'
            } @results;
            last unless @to_retry;

            local $options{jobs} = 1;  # force serial port allocation for retry
            print sprintf("\nRetry %d/%d for %d failed test(s) (serial)...\n",
                $attempt - 1, $max_attempts - 1, scalar @to_retry)
                unless $options{verbose};
            my %retry_by_name;
            for my $r (@to_retry) {
                my $name = $r->{name};
                print sprintf("  [retry %d] %s... ", $attempt - 1, $name)
                    unless $options{verbose};
                my $retried = run_test($name);
                $retry_by_name{$name} = $retried;
                unless ($options{verbose}) {
                    my $s = $retried->{status};
                    my $c = $s eq 'PASS' ? 'green'
                          : $s eq 'SKIP' ? 'yellow'
                          :                'red';
                    say colored($s, $c);
                }
            }
            # Replace originals with retry results.
            @results = map { $retry_by_name{$_->{name}} // $_ } @results;
        }
    } else {
        my $current = 0;
        for my $example (@$examples) {
            $current++;
            my $result = run_test($example);
            push @results, $result;
            _emit_result_line($current, $total, $result) unless $options{verbose};
        }
    }

    my $total_duration = time - $start_time;

    # Print summary
    print_summary(\@results, $total_duration);

    # Create diff files for all failed tests
    for my $result (@results) {
        if ($result->{status} eq 'FAIL') {
            create_diff_file($result);
        }
    }

    # Exit code
    my $failed = grep { $_->{status} eq 'FAIL' || $_->{status} eq 'ERROR' } @results;
    exit($failed > 0 ? 1 : 0);
}
1;
