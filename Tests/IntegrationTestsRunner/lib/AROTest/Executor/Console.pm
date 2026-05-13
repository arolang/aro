package AROTest::Executor::Console;

# Console executor: runs `aro run <dir>` (interpreter) or the compiled binary
# and captures merged stdout+stderr. The `--keep-alive` flow is for apps with
# an event loop — they need SIGINT after a beat to exit cleanly. run_debug_*
# is identical except it adds `--debug` to surface developer-context output.

use strict;
use warnings;
use v5.30;
use File::Spec;
use File::Basename;
use Time::HiRes qw(sleep);
use IPC::Run qw(start finish timeout kill_kill pump);
use Exporter 'import';

use AROTest::Utils qw($has_net_emptyport is_executable get_binary_path);
use AROTest::Config qw(%options $examples_dir);
use AROTest::Binary qw(find_aro_binary);

our @EXPORT_OK = qw(run_console_example run_console_example_internal run_debug_example);

# Public entry point — used by callers that don't care about mode/workdir.
sub run_console_example {
    my ($example_name) = @_;
    return run_console_example_internal($example_name, $options{timeout});
}

sub run_console_example_internal {
    my ($example_name, $timeout, $mode, $binary_name, $hints) = @_;
    $mode //= 'interpreter';

    my $keep_alive  = $hints && $hints->{'keep-alive'};
    my $allow_error = $hints && $hints->{'allow-error'};

    # Accept '.' or an absolute path verbatim; otherwise resolve under Examples/.
    my $dir;
    if ($example_name eq '.' || File::Spec->file_name_is_absolute($example_name)) {
        $dir = $example_name;
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }

    my @cmd;
    if ($mode eq 'compiled') {
        my $basename = defined $binary_name ? $binary_name : basename($dir);
        my $binary_path = get_binary_path($dir, $basename);
        unless (is_executable($binary_path)) {
            return (undef, "ERROR: Compiled binary not found at $binary_path");
        }
        @cmd = ($binary_path);
        push @cmd, '--keep-alive' if $keep_alive;
    } elsif ($mode eq 'test') {
        my $aro_bin = find_aro_binary();
        @cmd = ($aro_bin, 'test', $dir);
    } else {
        my $aro_bin = find_aro_binary();
        @cmd = ($aro_bin, 'run', $dir);
        push @cmd, '--keep-alive' if $keep_alive;
    }

    # Inject free-port env vars so examples that self-host HTTP/socket servers
    # don't conflict with sibling processes (e.g. kubectl port-forward on 8080).
    # In parallel mode each test gets a random port; in serial we prefer the
    # canonical ports so manual probes still work.
    local $ENV{ARO_HTTP_PORT}   = $ENV{ARO_HTTP_PORT}
        // ($has_net_emptyport ? ($options{jobs} > 1 ? Net::EmptyPort::empty_port() : Net::EmptyPort::empty_port(8080)) : 8080);
    local $ENV{ARO_SOCKET_PORT} = $ENV{ARO_SOCKET_PORT}
        // ($has_net_emptyport ? ($options{jobs} > 1 ? Net::EmptyPort::empty_port() : Net::EmptyPort::empty_port(9000)) : 9000);

    my ($in, $out, $err) = ('', '', '');
    my $handle = eval { start(\@cmd, \$in, \$out, \$err, timeout($timeout)); };
    return (undef, "Failed to start: $@") if $@;

    if ($keep_alive) {
        # Wait for app startup, drain pipe, then SIGINT for graceful shutdown.
        sleep 1;
        eval { pump $handle while $handle->pumpable && length($out) == 0 };
        say "  Sending SIGINT for graceful shutdown" if $options{verbose};
        eval { $handle->signal('INT'); };
        sleep 1;
        eval { pump $handle while $handle->pumpable };
    }

    eval { finish($handle); };
    if ($@) {
        if ($@ =~ /timeout/) {
            kill_kill($handle);
            if ($allow_error) {
                my $combined = $out;
                $combined .= $err if $err;
                return ($combined, undef);
            }
            return (undef, "TIMEOUT after ${timeout}s");
        }
        return (undef, "ERROR: $@") unless $allow_error;
    }

    my $combined = $out;
    $combined .= $err if $err;
    return ($combined, undef);
}

# Same flow with `--debug` appended. Used by multi-context tests to capture
# the developer context output for comparison against expected-debug.txt.
sub run_debug_example {
    my ($example_name, $timeout, $mode, $binary_name, $hints) = @_;
    $mode //= 'interpreter';

    my $keep_alive = $hints && $hints->{'keep-alive'};

    my $dir;
    if ($example_name eq '.' || File::Spec->file_name_is_absolute($example_name)) {
        $dir = $example_name;
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }

    my @cmd;
    if ($mode eq 'compiled') {
        my $basename = defined $binary_name ? $binary_name : basename($dir);
        my $binary_path = get_binary_path($dir, $basename);
        unless (is_executable($binary_path)) {
            return (undef, "ERROR: Compiled binary not found at $binary_path");
        }
        @cmd = ($binary_path, '--debug');
        push @cmd, '--keep-alive' if $keep_alive;
    } else {
        my $aro_bin = find_aro_binary();
        @cmd = ($aro_bin, 'run', '--debug', $dir);
        push @cmd, '--keep-alive' if $keep_alive;
    }

    local $ENV{ARO_HTTP_PORT}   = $ENV{ARO_HTTP_PORT}
        // ($has_net_emptyport ? ($options{jobs} > 1 ? Net::EmptyPort::empty_port() : Net::EmptyPort::empty_port(8080)) : 8080);
    local $ENV{ARO_SOCKET_PORT} = $ENV{ARO_SOCKET_PORT}
        // ($has_net_emptyport ? ($options{jobs} > 1 ? Net::EmptyPort::empty_port() : Net::EmptyPort::empty_port(9000)) : 9000);

    my ($in, $out, $err) = ('', '', '');
    my $handle = eval { start(\@cmd, \$in, \$out, \$err, timeout($timeout)); };
    return (undef, "Failed to start: $@") if $@;

    if ($keep_alive) {
        sleep 1;
        eval { pump $handle while $handle->pumpable && length($out) == 0 };
        say "  Sending SIGINT for graceful shutdown" if $options{verbose};
        eval { $handle->signal('INT'); };
        sleep 1;
        eval { pump $handle while $handle->pumpable };
    }

    eval { finish($handle); };
    if ($@) {
        if ($@ =~ /timeout/) {
            kill_kill($handle);
            return (undef, "TIMEOUT after ${timeout}s");
        }
        return (undef, "ERROR: $@");
    }

    my $combined = $out;
    $combined .= $err if $err;
    return ($combined, undef);
}

1;
