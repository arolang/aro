package AROTest::Executor::HTTP;

use strict;
use warnings;
use v5.30;
use parent 'AROTest::Executor::Base';
use File::Spec;

=head1 NAME

AROTest::Executor::HTTP - Execute HTTP server ARO examples

=head1 SYNOPSIS

    use AROTest::Executor::HTTP;

    my $executor = AROTest::Executor::HTTP->new($config);
    my ($output, $error) = $executor->execute('/path/to/example', 10);

=head1 DESCRIPTION

Executes HTTP server ARO examples by:
1. Parsing OpenAPI specification
2. Starting the HTTP server
3. Waiting for server readiness
4. Executing test requests in order
5. Capturing IDs from responses
6. Graceful shutdown

=cut

# Check for required modules
my $has_yaml = eval { require YAML::XS; 1; } || 0;
my $has_http_tiny = eval { require HTTP::Tiny; 1; } || 0;
my $has_net_emptyport = eval { require Net::EmptyPort; 1; } || 0;

=head2 execute($example_dir, $timeout)

Execute an HTTP server example.

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
    unless ($has_yaml && $has_http_tiny && $has_net_emptyport && $self->{has_ipc_run}) {
        return (undef, "SKIP: Missing required modules (YAML::XS, HTTP::Tiny, Net::EmptyPort, IPC::Run)");
    }

    my $openapi_file = File::Spec->catfile($example_dir, 'openapi.yaml');

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

    say "  Starting HTTP server on port $port" if $self->verbose;

    # Start server
    my $handle = $self->_start_server($example_dir, $timeout);
    return (undef, "Failed to start server") unless $handle;

    # Register cleanup handler
    my $cleanup = $self->_create_cleanup_handler($handle);
    $self->config->add_cleanup_handler($cleanup);

    # Wait for server to be ready
    unless ($self->_wait_for_server($port)) {
        $cleanup->();
        return (undef, "ERROR: Server did not start on port $port");
    }

    say "  Server ready, testing endpoints" if $self->verbose;

    # Test endpoints
    my $output = $self->_test_endpoints($spec, $port);

    # Cleanup
    $cleanup->();

    return ($output, undef);
}

# Start the HTTP server process
sub _start_server {
    my ($self, $example_dir, $timeout) = @_;

    my $aro_bin = AROTest::Binary::Locator::find_aro_binary();
    my ($in, $out, $err) = ('', '', '');

    my $handle = eval {
        IPC::Run::start([$aro_bin, 'run', $example_dir], \$in, \$out, \$err, IPC::Run::timeout($timeout));
    };

    if ($@) {
        warn "Failed to start server: $@\n";
        return undef;
    }

    return $handle;
}

# Create cleanup handler for graceful shutdown
sub _create_cleanup_handler {
    my ($self, $handle) = @_;

    return sub {
        eval {
            say "  [Cleanup] Starting cleanup..." if $self->verbose;

            # Check if handle has running processes
            unless ($handle->pumpable()) {
                say "  [Cleanup] No running processes to clean up" if $self->verbose;
                return 1;
            }

            say "  [Cleanup] Sending TERM signal for graceful shutdown" if $self->verbose;

            # Send TERM signal for graceful shutdown
            eval { $handle->signal('TERM'); };
            if ($@) {
                say "  [Cleanup] Warning: Failed to send TERM: $@" if $self->verbose;
            }

            # Wait up to 3 seconds for graceful shutdown
            my $max_wait = 3.0;
            my $waited = 0;
            while ($waited < $max_wait && $handle->pumpable()) {
                select(undef, undef, undef, 0.1);
                $waited += 0.1;
                eval { $handle->pump_nb(); };
            }

            # Check if process finished gracefully
            if (!$handle->pumpable()) {
                say "  [Cleanup] Process shut down gracefully" if $self->verbose;
                return 1;
            }

            # Force kill if still running
            say "  [Cleanup] Warning: Process did not shutdown gracefully, forcing kill" if $self->verbose;
            eval { $handle->kill_kill(); };

            return 1;
        } or do {
            my $error = $@ || "unknown error";
            say "  [Cleanup] Error during cleanup: $error" if $self->verbose;
        };
    };
}

# Wait for server to be ready
sub _wait_for_server {
    my ($self, $port) = @_;

    for (1..20) {  # Try for 10 seconds
        if (Net::EmptyPort::wait_port($port, 0.5)) {
            return 1;
        }
    }

    return 0;
}

# Test all endpoints from OpenAPI spec
sub _test_endpoints {
    my ($self, $spec, $port) = @_;

    my $http = HTTP::Tiny->new(timeout => 5);
    my @output;
    my %captured_ids;
    my $latest_created_id;

    # Extract and sort operations
    my @operations = $self->_extract_operations($spec);

    for my $op (@operations) {
        my ($path, $method, $operation, $operation_id) =
            @{$op}{qw(path method operation operation_id)};
        my $url = "http://localhost:$port$path";

        say "  Testing $method $path ($operation_id)" if $self->verbose;

        # Substitute path parameters
        my $test_url = $url;
        if ($test_url =~ /\{id\}/) {
            my $use_id = $latest_created_id || $captured_ids{$operation_id} || '123';
            $test_url =~ s/\{id\}/$use_id/g;
        }
        $test_url =~ s/\{(\w+)\}/test-$1/g;

        # Generate payload
        my $payload = $self->_generate_payload($operation_id, $operation);

        # Execute request
        my $response = $self->_execute_request($http, $method, $test_url, $payload);

        # Process response
        if ($response && $response->{success}) {
            push @output, sprintf("%s %s => %s", uc($method), $path, $response->{content});

            # Capture ID from response
            if ($response->{content} && $response->{content} =~ /"id"\s*:\s*"([^"]+)"/) {
                my $captured_id = $1;
                $captured_ids{$operation_id} = $captured_id;

                if ($operation_id =~ /^create/i || uc($method) eq 'POST') {
                    $latest_created_id = $captured_id;
                    say "  Captured ID: $captured_id (latest)" if $self->verbose;
                }
            }
        } elsif ($response) {
            push @output, sprintf("%s %s => ERROR: %s %s", uc($method), $path, $response->{status}, $response->{reason});
        } else {
            push @output, sprintf("%s %s => ERROR: No response", uc($method), $path);
        }
    }

    return join("\n", @output);
}

# Extract operations from OpenAPI spec
sub _extract_operations {
    my ($self, $spec) = @_;

    my @operations;
    return @operations unless $spec->{paths};

    for my $path (keys %{$spec->{paths}}) {
        for my $method (keys %{$spec->{paths}{$path}}) {
            next if $method =~ /^(parameters|servers|description)$/;

            my $operation = $spec->{paths}{$path}{$method};
            my $operation_id = $operation->{operationId} // '';

            push @operations, {
                path => $path,
                method => $method,
                operation => $operation,
                operation_id => $operation_id,
                has_params => ($path =~ /\{/ ? 1 : 0),
                order => $self->_get_operation_order($operation_id, $path),
            };
        }
    }

    # Sort operations by execution order
    @operations = sort {
        ($a->{order} // 50) <=> ($b->{order} // 50) ||
        (!$a->{has_params}) <=> (!$b->{has_params}) ||
        $a->{path} cmp $b->{path}
    } @operations;

    return @operations;
}

# Determine execution order for an operation
sub _get_operation_order {
    my ($self, $operation_id, $path) = @_;

    $operation_id //= '';
    $path //= '';

    return 10 if $operation_id =~ /^list/i;
    return 15 if $operation_id =~ /^get/i && $path =~ /\{/;
    return 20 if $operation_id =~ /^create/i;
    return 31 if $operation_id =~ /place/i;
    return 32 if $operation_id =~ /pay/i;
    return 33 if $operation_id =~ /ship/i;
    return 34 if $operation_id =~ /deliver/i;
    return 40 if $operation_id =~ /^update/i;
    return 50 if $operation_id =~ /^patch/i;
    return 91 if $operation_id =~ /cancel/i;
    return 95 if $operation_id =~ /^delete/i;

    return 50;  # Default middle priority
}

# Generate appropriate payload for operation
sub _generate_payload {
    my ($self, $operation_id, $operation) = @_;

    my %operation_payloads = (
        'createOrder' => '{"customerId":"test-customer","items":[{"productId":"test-product","quantity":1,"price":10.0}]}',
        'payOrder' => '{"paymentMethod":"credit_card","amount":10.0}',
        'shipOrder' => '{"carrier":"TestCarrier","trackingNumber":"TEST-123"}',
        'createUser' => '{"name":"Test User","email":"test@example.com"}',
        'updateUser' => '{"name":"Updated User"}',
        'create' => '{"name":"Test Item"}',
    );

    # Try exact match
    return $operation_payloads{$operation_id} if $operation_payloads{$operation_id};

    # Try partial match
    for my $pattern (keys %operation_payloads) {
        if ($operation_id =~ /$pattern/i) {
            return $operation_payloads{$pattern};
        }
    }

    return '{"data":"test"}';
}

# Execute HTTP request
sub _execute_request {
    my ($self, $http, $method, $url, $payload) = @_;

    if (uc($method) eq 'GET') {
        return $http->get($url);
    } elsif (uc($method) eq 'POST') {
        return $http->post($url, {
            headers => { 'Content-Type' => 'application/json' },
            content => $payload,
        });
    } elsif (uc($method) eq 'PUT') {
        return $http->put($url, {
            headers => { 'Content-Type' => 'application/json' },
            content => $payload,
        });
    } elsif (uc($method) eq 'DELETE') {
        return $http->delete($url);
    }

    return undef;
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
