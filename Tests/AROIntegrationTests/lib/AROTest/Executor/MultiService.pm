package AROTest::Executor::MultiService;

use strict;
use warnings;
use v5.30;
use parent 'AROTest::Executor::Base';
use IO::Socket::INET;
use IO::Select;
use File::Spec;
use JSON::PP qw(decode_json encode_json);

=head1 NAME

AROTest::Executor::MultiService - Execute multi-service ARO examples

=head1 DESCRIPTION

Executes multi-service ARO examples that combine HTTP server, TCP socket
server, and file monitoring. Tests all three channels:

1. HTTP requests and responses
2. Socket client: welcome message, broadcast notifications, file events
3. File operations: create and delete trigger socket notifications

=cut

# Check for required modules
my $has_net_emptyport = eval { require Net::EmptyPort; 1; } || 0;
my $has_http_tiny     = eval { require HTTP::Tiny; 1; } || 0;

sub execute {
    my ($self, $example_dir, $timeout, $hints) = @_;

    unless ($self->{has_ipc_run} && $has_net_emptyport && $has_http_tiny) {
        return (undef, "SKIP: Missing required modules (IPC::Run, Net::EmptyPort, HTTP::Tiny)");
    }

    my $http_port   = 8080;
    my $socket_port = 9000;
    my $watch_dir   = File::Spec->catdir('.', 'watched-dir');

    # Create watched directory if needed
    mkdir $watch_dir unless -d $watch_dir;

    say "  Starting multi-service app" if $self->verbose;

    my $aro_bin = AROTest::Binary::Locator::find_aro_binary();
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        IPC::Run::start([$aro_bin, 'run', $example_dir], \$in, \$out, \$err,
            IPC::Run::timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start multi-service app: $@");
    }

    # Register cleanup
    my $cleanup = sub {
        eval {
            unless ($handle->pumpable()) { return 1; }
            eval { $handle->signal('TERM'); };
            my $waited = 0;
            while ($waited < 3.0 && $handle->pumpable()) {
                select(undef, undef, undef, 0.1);
                $waited += 0.1;
                eval { $handle->pump_nb(); };
            }
            eval { $handle->kill_kill() } if $handle->pumpable();
        };
    };
    $self->config->add_cleanup_handler($cleanup);

    # Wait for both ports to be ready
    say "  Waiting for HTTP port $http_port" if $self->verbose;
    my $http_ready = 0;
    for (1..20) {
        if (Net::EmptyPort::wait_port($http_port, 0.5)) { $http_ready = 1; last; }
    }
    unless ($http_ready) {
        $cleanup->();
        return (undef, "ERROR: HTTP server did not start on port $http_port");
    }

    say "  Waiting for socket port $socket_port" if $self->verbose;
    my $socket_ready = 0;
    for (1..10) {
        if (Net::EmptyPort::wait_port($socket_port, 0.5)) { $socket_ready = 1; last; }
    }
    unless ($socket_ready) {
        $cleanup->();
        return (undef, "ERROR: Socket server did not start on port $socket_port");
    }

    # Connect socket client (stays open for the duration)
    my $sock = IO::Socket::INET->new(
        PeerAddr => 'localhost',
        PeerPort => $socket_port,
        Proto    => 'tcp',
        Timeout  => 5,
    );
    unless ($sock) {
        $cleanup->();
        return (undef, "ERROR: Could not connect to socket server: $!");
    }
    $sock->autoflush(1);

    my $sel = IO::Select->new($sock);

    # Helper: read all available socket lines within $wait seconds
    my $read_socket = sub {
        my ($wait) = @_;
        my @lines;
        my $deadline = time() + $wait;
        while (time() < $deadline) {
            my $remaining = $deadline - time();
            last if $remaining <= 0;
            if ($sel->can_read($remaining > 0.2 ? 0.2 : $remaining)) {
                my $line = <$sock>;
                last unless defined $line;
                chomp $line;
                push @lines, $line if length $line;
            }
        }
        return @lines;
    };

    my @output;

    # --- 1. Welcome message ---
    say "  Reading socket welcome message" if $self->verbose;
    my @welcome = $read_socket->(2);
    for my $line (@welcome) {
        push @output, "Socket: $line";
    }

    # --- 2. HTTP GET /status ---
    say "  HTTP GET /status" if $self->verbose;
    my $http = HTTP::Tiny->new(timeout => 5);
    my $status_resp = $http->get("http://localhost:$http_port/status");
    if ($status_resp->{success}) {
        my $body = _normalize_json($status_resp->{content});
        push @output, "GET /status => $body";
    } else {
        push @output, "GET /status => ERROR: " . $status_resp->{status};
    }

    # --- 3. Create file -> socket notification ---
    my $test_file = File::Spec->catfile($watch_dir, "ms_test_$$.txt");
    say "  Creating test file" if $self->verbose;
    { open(my $fh, '>', $test_file) or die "Cannot create $test_file: $!"; close $fh; }
    my @file_created = $read_socket->(3);
    for my $line (@file_created) {
        # Normalize the absolute path to just the filename
        my $normalized = $line;
        if ($normalized =~ s{FILE CREATED: .*/([^/]+)$}{FILE CREATED: $1}) {}
        push @output, "Socket: $normalized";
    }

    # --- 4. HTTP POST /broadcast ---
    say "  HTTP POST /broadcast" if $self->verbose;
    my $broadcast_resp = $http->post(
        "http://localhost:$http_port/broadcast",
        { headers => { 'Content-Type' => 'application/json' },
          content => encode_json({ message => 'Hello from HTTP!' }) }
    );
    if ($broadcast_resp->{success}) {
        my $body = _normalize_json($broadcast_resp->{content});
        push @output, "POST /broadcast => $body";
    } else {
        push @output, "POST /broadcast => ERROR: " . $broadcast_resp->{status};
    }

    # Read broadcast notification on socket
    my @broadcast_lines = $read_socket->(2);
    for my $line (@broadcast_lines) {
        push @output, "Socket: $line";
    }

    # --- 5. Delete file -> socket notification ---
    say "  Deleting test file" if $self->verbose;
    unlink $test_file if -f $test_file;
    my @file_deleted = $read_socket->(3);
    for my $line (@file_deleted) {
        my $normalized = $line;
        if ($normalized =~ s{FILE DELETED: .*/([^/]+)$}{FILE DELETED: $1}) {}
        push @output, "Socket: $normalized";
    }

    # Cleanup
    close $sock;
    $cleanup->();

    return (join("\n", @output), undef);
}

# Normalize JSON: parse and re-encode with sorted keys for deterministic output
sub _normalize_json {
    my ($json_str) = @_;
    my $data = eval { decode_json($json_str) };
    return $json_str unless defined $data && ref($data) eq 'HASH';

    # Re-encode with sorted keys
    my $encoder = JSON::PP->new->canonical(1);
    return $encoder->encode($data);
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
