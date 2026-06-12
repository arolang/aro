package AROTest::Pool;

# Fork-based test pool with serial-must-run carve-out, used when `--jobs > 1`.
# Children serialise their result hash via Storable into a per-test file in a
# shared temp dir; the parent reaps with non-blocking waitpid and prints
# results in completion order.
#
# `run_test` is injected as a callback so this module doesn't have to know
# about the executor stack.

use strict;
use warnings;
use v5.30;
use File::Spec;
use File::Temp qw(tempdir);
use POSIX ();
use Storable qw(nstore retrieve);
use Exporter 'import';

use AROTest::Config qw(%options);
use AROTest::Hint qw(read_test_hint);
use AROTest::Reporting qw(_emit_result_line);

our @EXPORT_OK = qw(run_pool requires_serial_run);

# Run a list of examples through a fork pool with at most $jobs concurrent
# children. $progress_total / $progress_offset let the caller stitch the
# parallel-batch + serial-batch invocations into one [N/total] counter.
sub run_pool {
    my ($examples, $jobs, $progress_total, $progress_offset, $run_test) = @_;
    return () unless @$examples;

    my $tmpdir = tempdir("aro-tests-XXXXXX", TMPDIR => 1, CLEANUP => 1);

    my %pid_to_name;
    my %pid_to_file;
    my @queue = @$examples;
    my @results;
    my $completed = 0;
    my $index = $progress_offset;

    # Worker-slot tracking so each forked child knows its own
    # 0..jobs-1 lane. HTTP.pm uses ARO_TEST_WORKER_ID to allocate
    # ports out of a worker-local non-overlapping range, which
    # closes the empty_port() probe race that hit SimpleChat
    # under -j > 1 (#297).
    my @free_slots = (0 .. ($jobs - 1));
    my %pid_to_slot;

    my $launch = sub {
        return unless @queue;
        return unless @free_slots;
        my $name = shift @queue;
        my $slot = shift @free_slots;
        my $file = File::Spec->catfile($tmpdir, "$name.result");
        my $pid = fork();
        die "fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            # Child: reset signal handlers so we don't echo the parent's
            # cleanup banner if killed.
            $SIG{INT} = $SIG{TERM} = 'DEFAULT';
            $ENV{ARO_TEST_WORKER_ID} = $slot;
            my $result = eval { $run_test->($name) } || {
                name                 => $name,
                type                 => 'UNKNOWN',
                interpreter_status   => 'ERROR',
                compiled_status      => 'N/A',
                interpreter_message  => "worker died: $@",
                compiled_message     => '',
                interpreter_duration => 0,
                compiled_duration    => 0,
                build_duration       => 0,
                avg_duration         => 0,
                status               => 'ERROR',
                duration             => 0,
            };
            eval { nstore($result, $file); };
            POSIX::_exit($@ ? 1 : 0);
        }
        $pid_to_name{$pid} = $name;
        $pid_to_file{$pid} = $file;
        $pid_to_slot{$pid} = $slot;
    };

    # Prime the pool — never launch more workers than examples.
    $launch->() for 1 .. ($jobs < @queue ? $jobs : scalar @queue);

    while (%pid_to_name) {
        my $pid = waitpid(-1, 0);
        last if $pid <= 0;
        my $name = delete $pid_to_name{$pid};
        my $file = delete $pid_to_file{$pid};
        my $slot = delete $pid_to_slot{$pid};
        # Return the freed slot to the pool so the next launch
        # picks it up; the port range it owns is now safe to reuse.
        push @free_slots, $slot if defined $slot;

        my $result;
        if ($file && -e $file) {
            $result = eval { retrieve($file) };
            unlink $file;
        }
        $result //= {
            name                 => $name // '<unknown>',
            type                 => 'UNKNOWN',
            interpreter_status   => 'ERROR',
            compiled_status      => 'N/A',
            interpreter_message  => "no result from worker (pid $pid exit \$?=$?)",
            compiled_message     => '',
            interpreter_duration => 0,
            compiled_duration    => 0,
            build_duration       => 0,
            avg_duration         => 0,
            status               => 'ERROR',
            duration             => 0,
        };

        push @results, $result;
        $completed++;
        $index++;
        _emit_result_line($index, $progress_total, $result) unless $options{verbose};

        $launch->();
    }

    return @results;
}

# Some examples bind hardcoded ports (8080 / 9000) or hold global state, so
# they have to run one at a time even when --jobs > 1.
sub requires_serial_run {
    my ($example_name) = @_;
    my $hints = read_test_hint($example_name);
    my $type = $hints->{type} // '';
    return 1 if $type eq 'socket'
             || $type eq 'socket-client'
             || $type eq 'multiservice';
    return 0;
}

1;
