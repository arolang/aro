package AROTest::Executor::Socket;

# Socket executor: starts a TCP socket-server example, connects a tiny test
# client, exchanges a few payloads, and captures the merged server log +
# client transcript. The client uses Net::EmptyPort for parallel-safe ports.

use strict;
use warnings;
use v5.30;
use File::Spec;
use File::Basename;
use Time::HiRes qw(time sleep);
use IPC::Run qw(start finish timeout kill_kill pump);
use Exporter 'import';

use AROTest::Utils qw($has_net_emptyport is_executable get_binary_path);
use AROTest::Config qw(%options $examples_dir @cleanup_handlers);
use AROTest::Binary qw(find_aro_binary);

our @EXPORT_OK = qw(run_socket_example run_socket_example_internal run_socket_client_example_internal);

sub run_socket_example {
    my ($example_name) = @_;
    return run_socket_example_internal($example_name, $options{timeout});
}

# Run socket example (internal with timeout parameter)
sub run_socket_example_internal {
    my ($example_name, $timeout, $mode, $binary_name) = @_;
    $mode //= 'interpreter';  # Default to interpreter mode

    unless ($has_net_emptyport) {
        return (undef, "SKIP: Missing required module (Net::EmptyPort)");
    }

    # Handle '.' or absolute paths directly, otherwise prepend examples_dir
    my $dir;
    if ($example_name eq '.' || File::Spec->file_name_is_absolute($example_name)) {
        $dir = $example_name;
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }

    my $port = 9000;  # Default socket port

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

    # Start server in background
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        start(\@cmd, \$in, \$out, \$err, timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start socket server: $@");
    }

    # Register cleanup with graceful shutdown
    my $cleanup = sub {
        eval {
            say "  [Cleanup] Starting cleanup..." if $options{verbose};

            # Check if handle has running processes
            unless ($handle->pumpable()) {
                say "  [Cleanup] No running processes to clean up" if $options{verbose};
                return 1;
            }

            say "  [Cleanup] Sending TERM signal for graceful shutdown" if $options{verbose};

            # Send TERM signal for graceful shutdown
            eval { $handle->signal('TERM'); };
            if ($@) {
                say "  [Cleanup] Warning: Failed to send TERM: $@" if $options{verbose};
            }

            # Wait up to 3 seconds for graceful shutdown
            my $max_wait = 3.0;
            my $waited = 0;
            while ($waited < $max_wait && $handle->pumpable()) {
                select(undef, undef, undef, 0.1);  # Sleep 0.1 seconds
                $waited += 0.1;

                # Pump to process any pending I/O and check status
                eval { $handle->pump_nb(); };
            }

            # Check if process finished gracefully
            if (!$handle->pumpable()) {
                say "  [Cleanup] Process shut down gracefully" if $options{verbose};
                return 1;
            }

            # If still running after 3 seconds, force kill
            say "  [Cleanup] Warning: Process did not shutdown gracefully, forcing kill" if $options{verbose};
            eval { $handle->kill_kill(); };
            if ($@) {
                say "  [Cleanup] Warning: kill_kill failed: $@" if $options{verbose};
            }

            return 1;
        } or do {
            my $error = $@ || "unknown error";
            say "  [Cleanup] Error during cleanup: $error" if $options{verbose};
        };
    };
    push @cleanup_handlers, $cleanup;

    # Wait for server to be ready
    my $ready = 0;
    for (1..20) {
        if (Net::EmptyPort::wait_port($port, 0.5)) {
            $ready = 1;
            last;
        }
    }

    unless ($ready) {
        $cleanup->();
        @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;
        return (undef, "ERROR: Socket server did not start on port $port");
    }

    say "  Socket server ready on port $port" if $options{verbose};

    # Connect and test
    use IO::Socket::INET;
    my $socket = IO::Socket::INET->new(
        PeerAddr => 'localhost',
        PeerPort => $port,
        Proto => 'tcp',
        Timeout => 5,
    );

    my @output;
    if ($socket) {
        print $socket "Hello, ARO!\n";
        my $response = <$socket>;
        chomp $response if defined $response;
        push @output, "Sent: Hello, ARO!";
        push @output, "Received: " . ($response // "NO RESPONSE");
        close $socket;
    } else {
        push @output, "ERROR: Could not connect to socket";
    }

    # Cleanup
    $cleanup->();
    @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;

    return (join("\n", @output), undef);
}

# Run socket CLIENT example (internal)
# Starts a Perl echo server, then runs the ARO app as the client.
# The ARO app Connects, Sends a message, and logs the echoed response.
sub run_socket_client_example_internal {
    my ($example_name, $timeout, $mode, $binary_name) = @_;
    $mode //= 'interpreter';

    unless ($has_net_emptyport) {
        return (undef, "SKIP: Missing required module (Net::EmptyPort)");
    }

    my $dir;
    if ($example_name eq '.' || File::Spec->file_name_is_absolute($example_name)) {
        $dir = $example_name;
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }

    my $port = 9001;  # Echo server port for socket-client test

    # Start a Perl echo server in a child process
    require POSIX;
    my $server_pid = fork();
    if (!defined $server_pid) {
        return (undef, "Failed to fork echo server: $!");
    }
    if ($server_pid == 0) {
        # Child: run a multi-connection echo server.
        # Reset signal handlers — the parent's cleanup-print handler would
        # otherwise fire here when we get killed at end-of-test.
        $SIG{INT} = $SIG{TERM} = 'DEFAULT';
        # Must loop on accept() because Net::EmptyPort::wait_port makes a probe
        # connection to detect readiness, which would consume a single-accept server.
        use IO::Socket::INET;
        my $server = IO::Socket::INET->new(
            LocalPort => $port,
            Type      => SOCK_STREAM,
            Reuse     => 1,
            Listen    => 5,
        ) or POSIX::_exit(1);
        while (my $client = $server->accept()) {
            my $child = fork();
            if ($child == 0) {
                $SIG{INT} = $SIG{TERM} = 'DEFAULT';
                close $server;
                $client->autoflush(1);
                my $buf = '';
                while (1) {
                    my $n = sysread($client, $buf, 4096);
                    last unless defined $n && $n > 0;
                    syswrite($client, $buf, $n);  # Echo back
                }
                close $client;
                POSIX::_exit(0);
            }
            close $client;
        }
        close $server;
        POSIX::_exit(0);
    }

    my $server_cleanup = sub {
        return unless $server_pid;
        eval {
            kill('TERM', $server_pid);
            select(undef, undef, undef, 0.2);
            kill('KILL', $server_pid);
            waitpid($server_pid, 0);
        };
        $server_pid = 0;
    };

    # Wait for echo server to be ready
    my $server_ready = 0;
    for (1..20) {
        if (Net::EmptyPort::wait_port($port, 0.5)) {
            $server_ready = 1;
            last;
        }
    }
    unless ($server_ready) {
        $server_cleanup->();
        return (undef, "ERROR: Echo server did not start on port $port");
    }

    say "  Echo server ready on port $port" if $options{verbose};

    # Determine ARO command
    my @cmd;
    if ($mode eq 'compiled') {
        my $basename = defined $binary_name ? $binary_name : basename($dir);
        my $binary_path = get_binary_path($dir, $basename);
        unless (is_executable($binary_path)) {
            $server_cleanup->();
            return (undef, "ERROR: Compiled binary not found at $binary_path");
        }
        @cmd = ($binary_path);
    } else {
        my $aro_bin = find_aro_binary();
        @cmd = ($aro_bin, 'run', $dir);
    }

    # Start ARO client app with IPC::Run to capture its output
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        start(\@cmd, \$in, \$out, \$err, timeout($timeout));
    };
    if ($@) {
        $server_cleanup->();
        return (undef, "Failed to start socket client app: $@");
    }

    my $aro_cleanup = sub {
        eval {
            return unless $handle->pumpable();
            $handle->signal('TERM');
            my $waited = 0;
            while ($waited < 3.0 && $handle->pumpable()) {
                select(undef, undef, undef, 0.1);
                $waited += 0.1;
                eval { $handle->pump_nb(); };
            }
            eval { $handle->kill_kill() } if $handle->pumpable();
        };
    };
    push @cleanup_handlers, $aro_cleanup;
    push @cleanup_handlers, $server_cleanup;

    # Wait for ARO app to log a received response
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        eval { $handle->pump_nb() };
        if ($out =~ /Received/s) {
            # Give it a moment to flush any remaining output
            select(undef, undef, undef, 0.3);
            eval { $handle->pump_nb() };
            last;
        }
        last unless $handle->pumpable();
        select(undef, undef, undef, 0.1);
    }

    # Cleanup
    $aro_cleanup->();
    @cleanup_handlers = grep { $_ != $aro_cleanup } @cleanup_handlers;
    $server_cleanup->();
    @cleanup_handlers = grep { $_ != $server_cleanup } @cleanup_handlers;

    return ($out, undef);
}

1;
