package AROTest::Executor::Socket;

use strict;
use warnings;
use v5.30;
use parent 'AROTest::Executor::Base';
use IO::Socket::INET;

=head1 NAME

AROTest::Executor::Socket - Execute socket server ARO examples

=head1 SYNOPSIS

    use AROTest::Executor::Socket;

    my $executor = AROTest::Executor::Socket->new($config);
    my ($output, $error) = $executor->execute('/path/to/example', 10);

=head1 DESCRIPTION

Executes socket server ARO examples by:
1. Starting the socket server
2. Waiting for server readiness
3. Connecting and sending test data
4. Capturing response
5. Graceful shutdown

=cut

# Check for required modules
my $has_net_emptyport = eval { require Net::EmptyPort; 1; } || 0;

=head2 execute($example_dir, $timeout)

Execute a socket server example.

Parameters:

=over 4

=item * C<$example_dir> - Path to example directory

=item * C<$timeout> - Timeout in seconds

=back

Returns: C<($output, $error)> where error is undef on success

=cut

sub execute {
    my ($self, $example_dir, $timeout) = @_;

    # Check required modules
    unless ($self->{has_ipc_run} && $has_net_emptyport) {
        return (undef, "SKIP: Missing required modules (IPC::Run, Net::EmptyPort)");
    }

    my $port = 9000;  # Default socket port

    say "  Starting socket server on port $port" if $self->verbose;

    # Start server
    my $aro_bin = AROTest::Binary::Locator::find_aro_binary();
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        IPC::Run::start([$aro_bin, 'run', $example_dir], \$in, \$out, \$err, IPC::Run::timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start socket server: $@");
    }

    # Register cleanup handler
    my $cleanup = sub {
        eval {
            say "  [Cleanup] Starting cleanup..." if $self->verbose;

            unless ($handle->pumpable()) {
                say "  [Cleanup] No running processes to clean up" if $self->verbose;
                return 1;
            }

            say "  [Cleanup] Sending TERM signal for graceful shutdown" if $self->verbose;
            eval { $handle->signal('TERM'); };

            # Wait up to 3 seconds for graceful shutdown
            my $max_wait = 3.0;
            my $waited = 0;
            while ($waited < $max_wait && $handle->pumpable()) {
                select(undef, undef, undef, 0.1);
                $waited += 0.1;
                eval { $handle->pump_nb(); };
            }

            if (!$handle->pumpable()) {
                say "  [Cleanup] Process shut down gracefully" if $self->verbose;
                return 1;
            }

            say "  [Cleanup] Warning: Process did not shutdown gracefully, forcing kill" if $self->verbose;
            eval { $handle->kill_kill(); };

            return 1;
        };
    };
    $self->config->add_cleanup_handler($cleanup);

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
        return (undef, "ERROR: Socket server did not start on port $port");
    }

    say "  Socket server ready, testing connection" if $self->verbose;

    # Connect and test
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

    return (join("\n", @output), undef);
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
