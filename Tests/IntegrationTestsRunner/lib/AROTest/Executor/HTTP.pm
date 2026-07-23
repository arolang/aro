package AROTest::Executor::HTTP;

# HTTP executor: starts the example's `aro run` (or compiled binary),
# probes the OpenAPI contract for routes, fires representative requests in
# a workflow-aware order (list → get → create → state transitions → delete),
# and concatenates server logs + per-request output into one blob for the
# expected.txt comparator.

use strict;
use warnings;
use v5.30;
use File::Spec;
use File::Basename;
use Time::HiRes qw(time sleep);
use IPC::Run qw(start finish timeout kill_kill pump);
use Exporter 'import';

use AROTest::Utils qw($has_yaml $has_http_tiny $has_net_emptyport is_executable get_binary_path);
use AROTest::Config qw(%options $examples_dir @cleanup_handlers);
use AROTest::Binary qw(find_aro_binary);

our @EXPORT_OK = qw(get_operation_order generate_test_payload run_http_example run_http_example_internal);

# Determine execution order for an operation (lower = earlier)
sub get_operation_order {
    my ($operation_id, $path) = @_;

    # Handle empty or undefined operation IDs
    $operation_id //= '';
    $path //= '';

    # Order groups (0-9 = setup, 10-19 = read, 20-29 = create, 30-89 = updates, 90-99 = cleanup)
    return 10 if $operation_id =~ /^list/i;              # List operations first
    return 15 if $operation_id =~ /^get/i && $path =~ /\{/;  # Get by ID after list
    return 20 if $operation_id =~ /^create/i;            # Create operations next

    # State transition order for common workflows
    return 31 if $operation_id =~ /place/i;              # place (draft -> placed)
    return 32 if $operation_id =~ /pay/i;                # pay (placed -> paid)
    return 33 if $operation_id =~ /ship/i;               # ship (paid -> shipped)
    return 34 if $operation_id =~ /deliver/i;            # deliver (shipped -> delivered)

    return 40 if $operation_id =~ /^update/i;            # Generic updates
    return 50 if $operation_id =~ /^patch/i;             # Patches

    return 91 if $operation_id =~ /cancel/i;             # Cancel near end
    return 95 if $operation_id =~ /^delete/i;            # Delete operations last

    return 50;  # Default middle priority
}

# Generate appropriate test payload based on operation ID and OpenAPI schema
sub generate_test_payload {
    my ($operation_id, $operation) = @_;

    # Operation-specific payloads for common patterns
    my %operation_payloads = (
        # Order management
        'createOrder' => '{"customerId":"test-customer","items":[{"productId":"test-product","quantity":1,"price":10.0}]}',
        'payOrder' => '{"paymentMethod":"credit_card","amount":10.0}',
        'shipOrder' => '{"carrier":"TestCarrier","trackingNumber":"TEST-123"}',

        # User management
        'createUser' => '{"name":"Test User","email":"test@example.com"}',
        'updateUser' => '{"name":"Updated User","email":"updated@example.com"}',

        # Chat / status
        'postStatus' => '{"message":"Test message"}',

        # Multi-service
        'broadcastMessage' => '{"message":"test"}',

        # Generic create operations
        'create' => '{"name":"Test Item"}',
    );

    # Try exact match first
    return $operation_payloads{$operation_id} if $operation_payloads{$operation_id};

    # Try partial match (e.g., createOrder matches create pattern)
    for my $pattern (keys %operation_payloads) {
        if ($operation_id =~ /$pattern/i) {
            return $operation_payloads{$pattern};
        }
    }

    # TODO: Parse OpenAPI requestBody schema for more accurate payloads
    # For now, return a generic payload
    return '{"data":"test"}';
}

# Run HTTP server example (public interface)
sub run_http_example {
    my ($example_name) = @_;
    return run_http_example_internal($example_name, $options{timeout});
}

# Run HTTP server example (internal with timeout parameter)
sub run_http_example_internal {
    my ($example_name, $timeout, $mode, $binary_name, $hints) = @_;
    $hints //= {};
    $mode //= 'interpreter';  # Default to interpreter mode

    unless ($has_yaml && $has_http_tiny && $has_net_emptyport) {
        return (undef, "SKIP: Missing required modules (YAML::XS, HTTP::Tiny, Net::EmptyPort)");
    }

    # Handle '.' or absolute paths directly, otherwise prepend examples_dir
    my $dir;
    if ($example_name eq '.' || File::Spec->file_name_is_absolute($example_name)) {
        $dir = $example_name;
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }

    my $openapi_file = File::Spec->catfile($dir, 'openapi.yaml');

    unless (-f $openapi_file) {
        return (undef, "ERROR: No openapi.yaml found");
    }

    # Parse OpenAPI spec
    my $spec = eval { YAML::XS::LoadFile($openapi_file) };
    if ($@) {
        return (undef, "ERROR: Failed to parse openapi.yaml: $@");
    }

    # Extract port from OpenAPI spec, then find a free port to avoid conflicts
    my $spec_port = 8080;
    if ($spec->{servers} && $spec->{servers}[0]{url}) {
        my $url = $spec->{servers}[0]{url};
        $spec_port = $1 if $url =~ /:(\d+)/;
    }
    # Use a free port so parallel runs and occupied ports don't conflict.
    # ARO_HTTP_PORT env var overrides the openapi.yaml port inside the server.
    #
    # Under -j > 1 the runner now assigns each forked worker an
    # ARO_TEST_WORKER_ID 0..jobs-1 (see Pool.pm). We allocate
    # ports out of a worker-local non-overlapping range so two
    # concurrent workers can never collide on the same port
    # (#297). Within a range Net::EmptyPort still probes for a
    # free slot — only same-worker races could remain, but a
    # single worker runs one example at a time, so they can't.
    # Serial runs keep $spec_port for stable observable output.
    my $port;
    if ($has_net_emptyport) {
        if ($options{jobs} > 1) {
            my $slot = $ENV{ARO_TEST_WORKER_ID} // 0;
            my $base = 30000 + ($slot * 1000);
            $port = Net::EmptyPort::empty_port($base);
        } else {
            $port = Net::EmptyPort::empty_port($spec_port);
        }
    } else {
        $port = $spec_port;
    }

    # Determine command based on mode
    my @cmd;
    my %extra_env = (ARO_HTTP_PORT => $port);

    # Some HTTP examples also start a socket server. SimpleChat, for
    # instance, binds a hardcoded port 9000 in main.aro. In "both" mode the
    # interpreter run is torn down and the compiled run started immediately
    # after; under slower/contended Linux CI the interpreter's NIO socket
    # server isn't always reaped in time, so it is still actively listening
    # on 9000 when the compiled native socket server tries to bind it.
    # SO_REUSEADDR does not permit two live listeners on the same port, so
    # the bind fails, the socket Start throws during Application-Start, the
    # app never serves, and every request surfaces as "599 Internal
    # Exception" (only reproduces in compiled mode on Linux CI; passes in
    # interpreter mode and on macOS).
    #
    # Hand the example a free ARO_SOCKET_PORT — which the runtime honors
    # over the {port:...} literal (resolvePort in ExecutionContext) — so it
    # can never collide with a 9000 held by the interpreter run, a leaked
    # process, or a concurrent worker. Mirrors what the MultiService and
    # Console executors already do.
    if ($has_net_emptyport) {
        my $socket_port;
        if ($options{jobs} > 1) {
            # Allocate from +500 within this worker's 1000-wide lane so it
            # stays clear of the HTTP port taken from the lane's base above.
            my $slot = $ENV{ARO_TEST_WORKER_ID} // 0;
            $socket_port = Net::EmptyPort::empty_port(30500 + ($slot * 1000));
        } else {
            $socket_port = Net::EmptyPort::empty_port(9000);
        }
        $extra_env{ARO_SOCKET_PORT} = $socket_port;
    }
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

    # Start server in background (with ARO_HTTP_PORT override)
    local %ENV = (%ENV, %extra_env);
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        start(\@cmd, \$in, \$out, \$err, timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start server: $@");
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
    for (1..20) {  # Try for 10 seconds
        if (Net::EmptyPort::wait_port($port, 0.5)) {
            $ready = 1;
            last;
        }
    }

    unless ($ready) {
        $cleanup->();
        @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;
        return (undef, "ERROR: Server did not start on port $port\nSTDERR: $err");
    }

    say "  Server ready on port $port" if $options{verbose};

    # Test endpoints
    # Disable keep-alive to avoid stale-connection issues between sequential
    # requests (HTTP::Tiny reuses sockets by default; if the server drops an
    # idle connection, the next request surfaces as "599 Internal Exception").
    my $http = HTTP::Tiny->new(timeout => 5, keep_alive => 0);
    my @output;
    my %captured_ids;  # Store IDs from responses for use in subsequent requests
    my $latest_created_id;  # Track the most recently created resource ID

    # Extract endpoints from OpenAPI spec
    if ($spec->{paths}) {
        # Build list of all operations with metadata
        my @operations;
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
                    order => (get_operation_order($operation_id, $path) // 50),
                };
            }
        }

        # Sort operations by execution order
        # Method priority: write operations (POST/PUT/PATCH) before reads (GET) on same path
        my %method_priority = (POST => 1, PUT => 2, PATCH => 3, GET => 4, DELETE => 5);
        @operations = sort {
            ($a->{order} // 50) <=> ($b->{order} // 50) ||
            (!$a->{has_params}) <=> (!$b->{has_params}) ||
            $a->{path} cmp $b->{path} ||
            ($method_priority{uc($a->{method})} // 3) <=> ($method_priority{uc($b->{method})} // 3)
        } @operations;

        for my $op (@operations) {
            my ($path, $method, $operation, $operation_id) =
                @{$op}{qw(path method operation operation_id)};
            my $url = "http://localhost:$port$path";

                # Substitute path parameters with captured IDs
                my $test_url = $url;
                if ($test_url =~ /\{id\}/) {
                    # Use the most recently created ID (from POST/PUT operations)
                    my $use_id = $latest_created_id || $captured_ids{$operation_id} || '123';
                    $test_url =~ s/\{id\}/$use_id/g;
                }
                $test_url =~ s/\{(\w+)\}/test-$1/g;

                # Add query parameters for GET requests based on OpenAPI spec
                if (uc($method) eq 'GET' && $operation->{parameters}) {
                    my @query_params;
                    for my $param (@{$operation->{parameters}}) {
                        next unless defined $param->{in} && $param->{in} eq 'query';
                        my $name = $param->{name};
                        my $value;

                        # Use example value if provided
                        if (defined $param->{example}) {
                            $value = $param->{example};
                        }
                        # Use schema default if provided
                        elsif ($param->{schema} && defined $param->{schema}{default}) {
                            $value = $param->{schema}{default};
                        }
                        # Use schema example if provided
                        elsif ($param->{schema} && defined $param->{schema}{example}) {
                            $value = $param->{schema}{example};
                        }
                        # Generate test value for required parameters
                        elsif ($param->{required}) {
                            $value = "test-$name";
                        }
                        # Skip optional parameters without defaults
                        else {
                            next;
                        }

                        # URL-encode the value
                        $value =~ s/([^a-zA-Z0-9_.-])/sprintf("%%%02X", ord($1))/ge;
                        push @query_params, "$name=$value";
                    }
                    if (@query_params) {
                        $test_url .= '?' . join('&', @query_params);
                    }
                }

                say "  Testing $method $path ($operation_id)" if $options{verbose};

                # Generate appropriate request payload based on operation
                my $payload = generate_test_payload($operation_id, $operation);

                # Retry once on HTTP::Tiny transport errors (status 599) — these are
                # typically transient connection issues, not real server errors.
                my $response;
                for my $attempt (1..2) {
                    if (uc($method) eq 'GET') {
                        $response = $http->get($test_url);
                    } elsif (uc($method) eq 'POST') {
                        $response = $http->post($test_url, {
                            headers => { 'Content-Type' => 'application/json' },
                            content => $payload,
                        });
                    } elsif (uc($method) eq 'PUT') {
                        $response = $http->put($test_url, {
                            headers => { 'Content-Type' => 'application/json' },
                            content => $payload,
                        });
                    } elsif (uc($method) eq 'DELETE') {
                        $response = $http->delete($test_url);
                    } else {
                        # Unsupported method, skip
                        last;
                    }
                    last if !$response || $response->{status} != 599;
                    select(undef, undef, undef, 0.1);  # brief pause before retry
                }
                next unless $response;

                if ($response && $response->{success}) {
                    my $content = $response->{content} // '';
                    push @output, sprintf("%s %s => %s", uc($method), $path, $content);

                    # Try to capture ID from response for subsequent requests
                    if ($response->{content} && $response->{content} =~ /"id"\s*:\s*"([^"]+)"/) {
                        my $captured_id = $1;
                        $captured_ids{$operation_id} = $captured_id;

                        # Track the latest created ID (from create operations)
                        if ($operation_id =~ /^create/i || uc($method) eq 'POST') {
                            $latest_created_id = $captured_id;
                            say "  Captured ID: $captured_id (latest)" if $options{verbose};
                        } else {
                            say "  Captured ID: $captured_id" if $options{verbose};
                        }
                    }
                } elsif ($response) {
                    push @output, sprintf("%s %s => ERROR: %s %s", uc($method), $path, $response->{status}, $response->{reason});
                    # Log full error content to STDERR for debugging (not included in test output)
                    if ($options{verbose} && $response->{content}) {
                        my $err_content = $response->{content};
                        $err_content =~ s/\s+/ /g;
                        say STDERR "  [DEBUG] $method $path error content: ", substr($err_content, 0, 300);
                    }
                } else {
                    push @output, sprintf("%s %s => ERROR: No response", uc($method), $path);
                }

                # Apply request delay if specified (allows async handlers to complete)
                if ($hints->{'request-delay'}) {
                    my $delay = $hints->{'request-delay'};
                    select(undef, undef, undef, $delay);
                }
        }
    }

    # Optionally collect server console output (for observer/event tests)
    if ($hints->{'include-server-output'}) {
        # Wait for async handlers (observers, event handlers) to complete.
        # Observers run on background event-loop tasks and their stdout can lag
        # behind the HTTP response, especially under CPU load or when multiple
        # observers are subscribed to the same repository. 2.5s is the budget
        # the macOS runner has previously needed for all three observer Tasks
        # to flush their last event's log line before we read the buffer.
        select(undef, undef, undef, 2.5);
        eval { $handle->pump_nb(); };  # Flush any remaining stdout

        # Parse accumulated server stdout — keep only observer/handler output lines,
        # strip startup/HTTP infrastructure lines, strip [FeatureName] prefix,
        # then sort for deterministic comparison.
        #
        # Interpreter mode: lines look like "[FeatureName] [CONTENT_PREFIX] message"
        #   → strip [FeatureName], leaving "[CONTENT_PREFIX] message" for sorting
        #   → normalize_output strips [CONTENT_PREFIX] later
        # Binary/compiled mode: lines look like "[CONTENT_PREFIX] message" (no outer wrapper)
        #   → keep as-is for sorting (same sort key as interpreter after one strip)
        #   → skip lines that don't start with "[" (startup messages like "Starting ...")
        #   → normalize_output strips [CONTENT_PREFIX] later
        my @server_lines;
        for my $line (split /\n/, $out) {
            # Skip empty lines and infrastructure lines
            next unless $line =~ /\S/;
            next if $line =~ /^\[Application-Start\]/;
            next if $line =~ /^HTTP Server started/;
            next if $line =~ /^\[ERROR\]/;   # runtime errors already visible

            if ($mode eq 'compiled') {
                my $is_occurrence_check = (defined $hints->{'occurrence-check'} && $hints->{'occurrence-check'} eq 'true');
                if (!$is_occurrence_check) {
                    # Exact-match mode: filter by [prefix] pattern to exclude startup/infrastructure lines
                    # (e.g. RepositoryObserver handlers log [AUDIT]/[CHANGE]/[MONITOR] prefixes)
                    next unless $line =~ /^\[/;
                    # Keep [CONTENT_PREFIX] intact — normalize_output strips it later,
                    # and it serves as the sort key (matching interpreter mode after one strip).
                }
                # occurrence-check mode: include all non-infrastructure lines as-is
                # (handler output without [prefix] is found via substring search)
            } else {
                # Interpreter mode: strip [FeatureName] wrapper so sort key is [CONTENT_PREFIX]
                $line =~ s/^\[[^\]]+\]\s+//;
            }
            push @server_lines, $line;
        }
        if (@server_lines) {
            my @sorted = sort @server_lines;
            push @output, "---server---";
            push @output, @sorted;
        }
    }

    # Cleanup
    $cleanup->();
    @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;

    return (join("\n", @output), undef);
}
1;
