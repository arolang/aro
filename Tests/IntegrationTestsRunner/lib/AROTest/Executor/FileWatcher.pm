package AROTest::Executor::FileWatcher;

# FileWatcher executor: runs a file-monitor example, then touches/creates
# files in its watched directory so the example's handlers fire. Captures
# the merged stdout/stderr for comparison.

use strict;
use warnings;
use v5.30;
use File::Spec;
use File::Basename;
use Time::HiRes qw(sleep);
use IPC::Run qw(start finish timeout kill_kill pump);
use Exporter 'import';

use AROTest::Utils qw(is_executable get_binary_path);
use AROTest::Config qw(%options $examples_dir @cleanup_handlers);
use AROTest::Binary qw(find_aro_binary);

our @EXPORT_OK = qw(run_file_watcher_example run_file_watcher_example_internal);

sub run_file_watcher_example {
    my ($example_name) = @_;
    return run_file_watcher_example_internal($example_name, $options{timeout});
}

# Run file watcher example (internal with timeout parameter)
sub run_file_watcher_example_internal {
    my ($example_name, $timeout, $mode, $binary_name) = @_;
    $mode //= 'interpreter';  # Default to interpreter mode

    # Handle '.' or absolute paths directly, otherwise prepend examples_dir
    my $dir;
    if ($example_name eq '.' || File::Spec->file_name_is_absolute($example_name)) {
        $dir = $example_name;
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }

    # Determine command based on mode
    my @cmd;
    if ($mode eq 'compiled') {
        # Execute compiled binary directly
        # Use provided binary_name (for workdir cases) or derive from dir
        my $basename = defined $binary_name ? $binary_name : basename($dir);
        my $binary_path = get_binary_path($dir, $basename);

        unless (is_executable($binary_path)) {
            return (undef, "ERROR: Compiled binary not found at $binary_path");
        }

        @cmd = ($binary_path);
    } elsif ($mode eq 'test') {
        # Use 'aro test' command
        my $aro_bin = find_aro_binary();
        @cmd = ($aro_bin, 'test', $dir);
    } else {
        # Interpreter mode (default)
        my $aro_bin = find_aro_binary();
        @cmd = ($aro_bin, 'run', $dir);
    }

    # Create test file directly in cwd (project root) so the FileMonitor library
    # (which only lists direct children of the watched directory) sees it as added/removed.
    my $test_file = File::Spec->catfile('.', "aro_fw_test_$$.txt");

    # Start watcher in background (use timeout parameter)
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        start(\@cmd, \$in, \$out, \$err, timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start file watcher: $@");
    }

    # Register cleanup
    my $cleanup = sub {
        eval {
            kill 'TERM', $handle->pid if $handle->pumpable;
            sleep 0.5;
            kill_kill($handle) if $handle->pumpable;
            unlink $test_file if -f $test_file;
        };
    };
    push @cleanup_handlers, $cleanup;

    # Wait for startup
    sleep 2;

    say "  Performing file operations" if $options{verbose};

    # Create file
    system("touch $test_file");
    sleep 1;

    # Modify file
    system("echo 'test' >> $test_file");
    sleep 1;

    # Delete file
    unlink $test_file;
    sleep 1;

    # Signal the watcher to stop (it uses Keepalive, so it won't exit on its own)
    eval { $handle->signal('TERM'); };
    sleep 1;

    # Capture output — process should exit promptly after TERM
    eval { finish($handle) };

    # Cleanup
    $cleanup->();
    @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;

    # Combine stdout and stderr
    my $combined = $out;
    $combined .= $err if $err;
    return ($combined, undef);
}

1;
