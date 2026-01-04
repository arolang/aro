package AROTest::Binary::Execution;

use strict;
use warnings;
use v5.30;
use File::Spec;
use File::Basename;
use Time::HiRes qw(time);
use AROTest::Binary::Locator qw(find_aro_binary find_example_binary);
use Exporter 'import';

our @EXPORT_OK = qw(build_binary execute_binary);

=head1 NAME

AROTest::Binary::Execution - Build and execute compiled ARO binaries

=head1 SYNOPSIS

    use AROTest::Binary::Execution qw(build_binary execute_binary);

    my ($binary, $error, $build_time) = build_binary($example_name, $example_dir);
    my ($output, $error, $exec_time) = execute_binary($binary, $type, $timeout, $config);

=head1 DESCRIPTION

Handles building ARO examples to native binaries and executing them
based on test type.

=cut

# Check for required modules
my $has_ipc_run = eval { require IPC::Run; 1; } || 0;
my $has_yaml = eval { require YAML::XS; 1; } || 0;
my $has_http_tiny = eval { require HTTP::Tiny; 1; } || 0;
my $has_net_emptyport = eval { require Net::EmptyPort; 1; } || 0;

=head2 build_binary($example_name, $example_dir)

Build an ARO example to a native binary using C<aro build>.

Parameters:

=over 4

=item * C<$example_name> - Name of the example

=item * C<$example_dir> - Path to example directory

=back

Returns: C<($binary_path, $error, $build_time)>

=cut

sub build_binary {
    my ($example_name, $example_dir) = @_;

    my $aro_bin = find_aro_binary();
    my $build_start = time;
    my $build_output = `$aro_bin build $example_dir 2>&1`;
    my $build_time = time - $build_start;

    if ($? != 0) {
        return (undef, "BUILD ERROR: $build_output", $build_time);
    }

    # Find the binary
    my $binary = find_example_binary($example_name, $example_dir);
    unless ($binary && -x $binary) {
        return (undef, "Binary not found after build", $build_time);
    }

    return ($binary, undef, $build_time);
}

=head2 execute_binary($binary, $type, $timeout, $config)

Execute a compiled binary based on test type.

Parameters:

=over 4

=item * C<$binary> - Path to the compiled binary

=item * C<$type> - Test type (console, http, socket, file)

=item * C<$timeout> - Timeout in seconds

=item * C<$config> - AROTest::Config instance

=back

Returns: C<($output, $error, $exec_time)>

=cut

sub execute_binary {
    my ($binary, $type, $timeout, $config) = @_;

    my $exec_start = time;
    my ($output, $error);

    if ($type eq 'console') {
        ($output, $error) = _execute_console($binary, $timeout);
    } elsif ($type eq 'http') {
        ($output, $error) = _execute_http($binary, $timeout, $config);
    } elsif ($type eq 'socket') {
        ($output, $error) = _execute_socket($binary, $timeout, $config);
    } elsif ($type eq 'file') {
        ($output, $error) = _execute_file($binary, $timeout, $config);
    } else {
        ($output, $error) = (undef, "Unknown test type: $type");
    }

    my $exec_time = time - $exec_start;
    return ($output, $error, $exec_time);
}

# Execute console binary
sub _execute_console {
    my ($binary, $timeout) = @_;

    if ($has_ipc_run) {
        my ($in, $out, $err) = ('', '', '');
        my $handle = eval {
            IPC::Run::start([$binary], \$in, \$out, \$err, IPC::Run::timeout($timeout));
        };

        if ($@) {
            return (undef, "Failed to start binary: $@");
        }

        eval { IPC::Run::finish($handle); };

        if ($@) {
            if ($@ =~ /timeout/) {
                IPC::Run::kill_kill($handle);
                return (undef, "TIMEOUT after ${timeout}s");
            }
            return (undef, "ERROR: $@");
        }

        return ($out, undef);
    } else {
        my $output = `$binary 2>&1`;
        my $exit_code = $? >> 8;
        if ($exit_code != 0) {
            return (undef, "Exit code: $exit_code\n$output");
        }
        return ($output, undef);
    }
}

# Execute HTTP server binary (reuses HTTP test logic)
sub _execute_http {
    my ($binary, $timeout, $config) = @_;

    unless ($has_yaml && $has_http_tiny && $has_net_emptyport && $has_ipc_run) {
        return (undef, "SKIP: Missing required modules (YAML::XS, HTTP::Tiny, Net::EmptyPort, IPC::Run)");
    }

    # Get directory from binary path to find openapi.yaml
    my $dir = File::Basename::dirname($binary);
    my $openapi_file = File::Spec->catfile($dir, 'openapi.yaml');

    unless (-f $openapi_file) {
        return (undef, "ERROR: No openapi.yaml found");
    }

    # Parse OpenAPI spec
    my $spec = eval { YAML::XS::LoadFile($openapi_file) };
    if ($@) {
        return (undef, "ERROR: Failed to parse openapi.yaml: $@");
    }

    # Extract port
    my $port = 8080;
    if ($spec->{servers} && $spec->{servers}[0]{url}) {
        my $url = $spec->{servers}[0]{url};
        $port = $1 if $url =~ /:(\d+)/;
    }

    # Start server
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        IPC::Run::start([$binary], \$in, \$out, \$err, IPC::Run::timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start binary: $@");
    }

    # Wait for server
    my $ready = 0;
    for (1..20) {
        if (Net::EmptyPort::wait_port($port, 0.5)) {
            $ready = 1;
            last;
        }
    }

    unless ($ready) {
        eval { $handle->kill_kill(); };
        return (undef, "ERROR: Server did not start on port $port");
    }

    # Test endpoints (simplified version)
    require HTTP::Tiny;
    my $http = HTTP::Tiny->new(timeout => 5);
    my @output;

    if ($spec->{paths}) {
        for my $path (sort keys %{$spec->{paths}}) {
            for my $method (sort keys %{$spec->{paths}{$path}}) {
                next if $method =~ /^(parameters|servers|description)$/;

                my $test_url = "http://localhost:$port$path";
                $test_url =~ s/\{(\w+)\}/test-$1/g;

                my $response;
                if (uc($method) eq 'GET') {
                    $response = $http->get($test_url);
                } elsif (uc($method) eq 'POST') {
                    $response = $http->post($test_url, {
                        headers => { 'Content-Type' => 'application/json' },
                        content => '{"data":"test"}',
                    });
                }

                if ($response && $response->{success}) {
                    push @output, sprintf("%s %s => %s", uc($method), $path, $response->{content});
                }
            }
        }
    }

    # Cleanup
    eval { $handle->kill_kill(); };

    return (join("\n", @output), undef);
}

# Execute socket server binary
sub _execute_socket {
    my ($binary, $timeout, $config) = @_;

    unless ($has_ipc_run && $has_net_emptyport) {
        return (undef, "SKIP: Missing required modules (IPC::Run, Net::EmptyPort)");
    }

    my $port = 9000;

    # Start server
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        IPC::Run::start([$binary], \$in, \$out, \$err, IPC::Run::timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start binary: $@");
    }

    # Wait for server
    my $ready = 0;
    for (1..20) {
        if (Net::EmptyPort::wait_port($port, 0.5)) {
            $ready = 1;
            last;
        }
    }

    unless ($ready) {
        eval { $handle->kill_kill(); };
        return (undef, "ERROR: Socket server did not start on port $port");
    }

    # Test connection
    require IO::Socket::INET;
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
    }

    # Cleanup
    eval { $handle->kill_kill(); };

    return (join("\n", @output), undef);
}

# Execute file watcher binary
sub _execute_file {
    my ($binary, $timeout, $config) = @_;

    unless ($has_ipc_run) {
        return (undef, "SKIP: Missing required module (IPC::Run)");
    }

    my $test_file = "/tmp/aro_test_$$.txt";

    # Start watcher
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        IPC::Run::start([$binary], \$in, \$out, \$err, IPC::Run::timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start binary: $@");
    }

    sleep 2;  # Wait for startup

    # Trigger file events
    system("touch $test_file");
    sleep 1;
    system("echo 'test' >> $test_file");
    sleep 1;
    unlink $test_file;
    sleep 1;

    # Capture output
    eval { IPC::Run::finish($handle, IPC::Run::timeout(2)) };

    return ($out, undef);
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
