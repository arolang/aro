#!/usr/bin/env perl
use strict;
use warnings;
use v5.30;
use FindBin qw($RealBin);
use Cwd qw(abs_path cwd);

# Core modules
use File::Spec;
use File::Basename;
use Getopt::Long;
use Time::HiRes qw(time sleep);

# Try to load optional modules, fall back to basic functionality if not available
my $has_ipc_run = eval { require IPC::Run; 1; } || 0;
my $has_yaml = eval { require YAML::XS; 1; } || 0;
my $has_http_tiny = eval { require HTTP::Tiny; 1; } || 0;
my $has_net_emptyport = eval { require Net::EmptyPort; 1; } || 0;
my $has_term_color = eval { require Term::ANSIColor; 1; } || 0;

# Colored output helper
sub colored {
    my ($text, $color) = @_;
    return $text unless $has_term_color;
    return Term::ANSIColor::colored($text, $color);
}

# Configuration
my %options = (
    generate => 0,
    verbose => 0,
    timeout => 10,
    filter => '',
    help => 0,
);

GetOptions(
    'generate' => \$options{generate},
    'verbose|v' => \$options{verbose},
    'timeout=i' => \$options{timeout},
    'filter=s' => \$options{filter},
    'help|h' => \$options{help},
) or die "Invalid options. Use --help for usage.\n";

if ($options{help}) {
    print_usage();
    exit 0;
}

sub print_usage {
    print <<'USAGE';
ARO Examples Test Harness

Usage:
    ./test-examples.pl [OPTIONS] [EXAMPLE]

Options:
    --generate          Generate expected.txt files for all examples
    -v, --verbose       Show detailed output
    --timeout=N         Timeout in seconds for long-running examples (default: 10)
    --filter=PATTERN    Test only examples matching pattern
    -h, --help          Show this help

Examples:
    # Generate all expected outputs
    ./test-examples.pl --generate

    # Run all tests
    ./test-examples.pl

    # Test only HTTP examples
    ./test-examples.pl --filter=HTTP

    # Test single example
    ./test-examples.pl HelloWorld

    # Verbose mode
    ./test-examples.pl --verbose

Required Perl Modules:
    IPC::Run           - Process management (recommended)
    YAML::XS           - OpenAPI parsing (for HTTP tests)
    HTTP::Tiny         - HTTP client (for HTTP tests)
    Net::EmptyPort     - Port detection (for HTTP/socket tests)
    Term::ANSIColor    - Colored output (optional)

Install with: cpan -i IPC::Run YAML::XS HTTP::Tiny Net::EmptyPort Term::ANSIColor
USAGE
}

# Globals
my $examples_dir = File::Spec->catdir($RealBin, 'Examples');
my %results;
my @cleanup_handlers;

# Signal handling for cleanup
$SIG{INT} = $SIG{TERM} = sub {
    warn "\nCaught signal, cleaning up...\n";
    $_->() for @cleanup_handlers;
    exit 1;
};

# Main execution
sub main {
    unless (-d $examples_dir) {
        die "Examples directory not found: $examples_dir\n";
    }

    # Check for required modules
    unless ($has_ipc_run) {
        warn "Warning: IPC::Run not installed. Using fallback process management.\n";
        warn "Install with: cpan -i IPC::Run\n\n";
    }

    my @examples;
    if (@ARGV) {
        # Test specific examples provided as arguments
        @examples = @ARGV;
    } else {
        # Discover all examples
        @examples = discover_examples();
    }

    # Apply filter
    if ($options{filter}) {
        @examples = grep { /$options{filter}/i } @examples;
    }

    unless (@examples) {
        die "No examples found matching criteria.\n";
    }

    if ($options{generate}) {
        generate_all_expected(\@examples);
    } else {
        run_all_tests(\@examples);
    }
}

# Discover all example directories
sub discover_examples {
    opendir my $dh, $examples_dir or die "Cannot open $examples_dir: $!";
    my @examples = grep {
        -d File::Spec->catdir($examples_dir, $_) &&
        !/^\./ &&
        $_ ne 'template'
    } readdir $dh;
    closedir $dh;

    return sort @examples;
}

# Read test.hint file for an example if it exists
# Returns hash reference with parsed directives
sub read_test_hint {
    my ($example_name) = @_;

    my $hint_file = File::Spec->catfile($examples_dir, $example_name, 'test.hint');
    my %hints = (
        workdir => undef,
        timeout => undef,
        type => undef,
        skip => undef,
        'pre-script' => undef,
        'test-script' => undef,
        'occurrence-check' => undef,
    );

    # Return empty hints if file doesn't exist (backward compatible)
    return \%hints unless -f $hint_file;

    open my $fh, '<', $hint_file or do {
        warn "Warning: Cannot read $hint_file: $!\n" if $options{verbose};
        return \%hints;
    };

    my $line_no = 0;
    while (my $line = <$fh>) {
        $line_no++;

        # Strip whitespace
        chomp $line;
        $line =~ s/^\s+|\s+$//g;

        # Skip comments and blank lines
        next if !$line || $line =~ /^#/;

        # Parse key: value
        if ($line =~ /^([^:]+):\s*(.*)$/) {
            my $key = lc $1;
            my $value = $2;

            # Strip value whitespace
            $value =~ s/^\s+|\s+$//g;

            # Validate and store
            if (exists $hints{$key}) {
                if (defined $hints{$key} && $options{verbose}) {
                    warn "Warning: $hint_file:$line_no duplicate key '$key' (overriding)\n";
                }
                $hints{$key} = $value;
            } elsif ($options{verbose}) {
                warn "Warning: $hint_file:$line_no unknown directive '$key'\n";
            }
        } elsif ($options{verbose}) {
            warn "Warning: $hint_file:$line_no malformed line (expected 'key: value'): $line\n";
        }
    }

    close $fh;

    # Validate values
    if (defined $hints{timeout} && $hints{timeout} !~ /^\d+$/) {
        warn "Warning: Invalid timeout value '$hints{timeout}' (must be integer), ignoring\n";
        $hints{timeout} = undef;
    }

    if (defined $hints{type} && $hints{type} !~ /^(console|http|socket|file)$/) {
        warn "Warning: Invalid type '$hints{type}' (must be console|http|socket|file), ignoring\n";
        $hints{type} = undef;
    }

    return \%hints;
}

# Run test with specified working directory
# Handles chdir, executes appropriate test runner, restores original directory
sub run_test_in_workdir {
    my ($example_name, $workdir, $timeout, $type, $pre_script) = @_;

    my $orig_cwd = cwd();
    my $output;
    my $error;
    my $run_dir = $example_name;  # Default: use example name as-is

    # Change directory if specified
    if (defined $workdir) {
        # Convert relative path to absolute (relative to project root)
        my $abs_workdir = $workdir;
        unless (File::Spec->file_name_is_absolute($workdir)) {
            $abs_workdir = File::Spec->catdir($RealBin, $workdir);
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
    if ($type eq 'console') {
        ($output, $error) = run_console_example_internal($run_dir, $timeout);
    } elsif ($type eq 'http') {
        ($output, $error) = run_http_example_internal($run_dir, $timeout);
    } elsif ($type eq 'socket') {
        ($output, $error) = run_socket_example_internal($run_dir, $timeout);
    } elsif ($type eq 'file') {
        ($output, $error) = run_file_watcher_example_internal($run_dir, $timeout);
    }

    # Restore original directory
    unless (chdir $orig_cwd) {
        warn "WARNING: Cannot restore directory $orig_cwd: $!\n";
    }

    return ($output, $error);
}

# Run a shell script with timeout support
sub run_script {
    my ($script, $timeout, $context) = @_;

    unless ($has_ipc_run) {
        return (undef, "IPC::Run module not available", -1);
    }

    # Use IPC::Run for timeout support
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        IPC::Run::start(['sh', '-c', $script], \$in, \$out, \$err,
                       IPC::Run::timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start $context: $@", -1);
    }

    # Wait for completion
    eval { $handle->finish; };
    my $exit_code = $? >> 8;

    return ($out, $err, $exit_code);
}

# Detect example type
sub detect_example_type {
    my ($example_name) = @_;

    my $dir = File::Spec->catdir($examples_dir, $example_name);

    # Check for OpenAPI contract with non-empty paths
    if (-f File::Spec->catfile($dir, 'openapi.yaml')) {
        # Only treat as HTTP if the spec has actual paths defined
        if ($has_yaml) {
            my $has_paths = 0;
            eval {
                my $spec = YAML::XS::LoadFile(File::Spec->catfile($dir, 'openapi.yaml'));
                $has_paths = 1 if $spec->{paths} && keys %{$spec->{paths}} > 0;
            };
            # Return 'http' if we found actual paths
            return 'http' if $has_paths;
            # Otherwise fall through to console detection
        } else {
            # If YAML::XS not available, assume HTTP (conservative)
            return 'http';
        }
    }

    # Check ARO source for specific patterns
    my @aro_files = glob File::Spec->catfile($dir, '*.aro');
    for my $file (@aro_files) {
        open my $fh, '<', $file or next;
        my $content = do { local $/; <$fh> };
        close $fh;

        return 'socket' if $content =~ /<Start>\s+the\s+<socket-server>/;
        return 'file' if $content =~ /<Start>\s+the\s+<file-monitor>/;
    }

    return 'console';
}

# Normalize output for comparison
sub normalize_output {
    my ($output, $type) = @_;

    # Remove ISO timestamps
    $output =~ s/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?/__TIMESTAMP__/g;

    # Normalize ls -la timestamps (month day time/year before filename)
    # Matches: "Jan  3 12:26" or "Dec 31  2025" in ls output
    $output =~ s/^([\-dlrwxs@+]+\s+\d+\s+\w+\s+\w+\s+\d+\s+)\w+\s+\d+\s+[\d:]+/$1__DATE__/gm;

    # Normalize paths (absolute -> relative)
    my $base_dir = $RealBin;
    $output =~ s/\Q$base_dir\E/./g;

    # Normalize line endings
    $output =~ s/\r\n/\n/g;

    # Remove trailing whitespace
    $output =~ s/ +$//gm;

    # Normalize hash values (for HashTest example)
    $output =~ s/\b[a-f0-9]{32,64}\b/__HASH__/g if $type && $type eq 'hash';

    return $output;
}

# Check if all expected lines occur in output (order-independent)
sub check_output_occurrences {
    my ($actual, $expected) = @_;

    # Split into lines
    my @expected_lines = split /\n/, $expected;
    my @missing = ();

    # Check each expected line appears in actual output
    for my $expected_line (@expected_lines) {
        # Skip empty lines
        next if $expected_line =~ /^\s*$/;

        # Escape regex metacharacters in expected line
        my $pattern = quotemeta($expected_line);

        # Check if line appears anywhere in actual output
        unless ($actual =~ /$pattern/m) {
            push @missing, $expected_line;
        }
    }

    # If no missing lines, test passes
    return (scalar(@missing) == 0, \@missing);
}

# Run console example (public interface)
sub run_console_example {
    my ($example_name) = @_;
    return run_console_example_internal($example_name, $options{timeout});
}

# Run console example (internal with timeout parameter)
sub run_console_example_internal {
    my ($example_name, $timeout) = @_;

    # Handle '.' or absolute paths directly, otherwise prepend examples_dir
    my $dir;
    if ($example_name eq '.' || File::Spec->file_name_is_absolute($example_name)) {
        $dir = $example_name;
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }

    if ($has_ipc_run) {
        # Use IPC::Run for better control
        # Use absolute path to aro binary (works even when cwd changes)
        my $aro_bin = File::Spec->catfile($RealBin, '.build', 'release', 'aro');
        my ($in, $out, $err) = ('', '', '');
        my $handle = eval {
            IPC::Run::start([$aro_bin, 'run', $dir], \$in, \$out, \$err, IPC::Run::timeout($timeout));
        };

        if ($@) {
            return (undef, "Failed to start: $@");
        }

        eval {
            IPC::Run::finish($handle);
        };

        if ($@) {
            if ($@ =~ /timeout/) {
                IPC::Run::kill_kill($handle);
                return (undef, "TIMEOUT after ${timeout}s");
            }
            return (undef, "ERROR: $@");
        }

        return ($out, undef);
    } else {
        # Fallback to system()
        my $output = `.build/release/aro run $dir 2>&1`;
        my $exit_code = $? >> 8;

        if ($exit_code != 0) {
            return (undef, "Exit code: $exit_code\n$output");
        }

        return ($output, undef);
    }
}

# Run HTTP server example (public interface)
sub run_http_example {
    my ($example_name) = @_;
    return run_http_example_internal($example_name, $options{timeout});
}

# Run HTTP server example (internal with timeout parameter)
sub run_http_example_internal {
    my ($example_name, $timeout) = @_;

    unless ($has_yaml && $has_http_tiny && $has_net_emptyport && $has_ipc_run) {
        return (undef, "SKIP: Missing required modules (YAML::XS, HTTP::Tiny, Net::EmptyPort, IPC::Run)");
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

    # Extract port
    my $port = 8080;
    if ($spec->{servers} && $spec->{servers}[0]{url}) {
        my $url = $spec->{servers}[0]{url};
        $port = $1 if $url =~ /:(\d+)/;
    }

    # Start server in background (use timeout parameter)
    # Use absolute path to aro binary (works even when cwd changes)
    my $aro_bin = File::Spec->catfile($RealBin, '.build', 'release', 'aro');
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        IPC::Run::start([$aro_bin, 'run', $dir], \$in, \$out, \$err, IPC::Run::timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start server: $@");
    }

    # Register cleanup
    my $cleanup = sub {
        eval {
            kill 'TERM', $handle->pid if $handle->pumpable;
            sleep 0.5;
            IPC::Run::kill_kill($handle) if $handle->pumpable;
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
    my $http = HTTP::Tiny->new(timeout => 5);
    my @output;

    # Extract endpoints from OpenAPI spec
    if ($spec->{paths}) {
        for my $path (sort keys %{$spec->{paths}}) {
            for my $method (sort keys %{$spec->{paths}{$path}}) {
                next if $method =~ /^(parameters|servers|description)$/;

                my $operation = $spec->{paths}{$path}{$method};
                my $url = "http://localhost:$port$path";

                say "  Testing $method $path" if $options{verbose};

                my $response;
                if (uc($method) eq 'GET') {
                    $response = $http->get($url);
                } elsif (uc($method) eq 'POST') {
                    $response = $http->post($url, {
                        headers => { 'Content-Type' => 'application/json' },
                        content => '{"message":"test"}',
                    });
                }

                if ($response->{success}) {
                    push @output, sprintf("%s %s => %s", uc($method), $path, $response->{content});
                } else {
                    push @output, sprintf("%s %s => ERROR: %s %s", uc($method), $path, $response->{status}, $response->{reason});
                }
            }
        }
    }

    # Cleanup
    $cleanup->();
    @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;

    return (join("\n", @output), undef);
}

# Run socket example (public interface)
sub run_socket_example {
    my ($example_name) = @_;
    return run_socket_example_internal($example_name, $options{timeout});
}

# Run socket example (internal with timeout parameter)
sub run_socket_example_internal {
    my ($example_name, $timeout) = @_;

    unless ($has_ipc_run && $has_net_emptyport) {
        return (undef, "SKIP: Missing required modules (IPC::Run, Net::EmptyPort)");
    }

    # Handle '.' or absolute paths directly, otherwise prepend examples_dir
    my $dir;
    if ($example_name eq '.' || File::Spec->file_name_is_absolute($example_name)) {
        $dir = $example_name;
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }

    my $port = 9000;  # Default socket port

    # Start server in background (use timeout parameter)
    # Use absolute path to aro binary (works even when cwd changes)
    my $aro_bin = File::Spec->catfile($RealBin, '.build', 'release', 'aro');
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        IPC::Run::start([$aro_bin, 'run', $dir], \$in, \$out, \$err, IPC::Run::timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start socket server: $@");
    }

    # Register cleanup
    my $cleanup = sub {
        eval {
            kill 'TERM', $handle->pid if $handle->pumpable;
            sleep 0.5;
            IPC::Run::kill_kill($handle) if $handle->pumpable;
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

# Run file watcher example (public interface)
sub run_file_watcher_example {
    my ($example_name) = @_;
    return run_file_watcher_example_internal($example_name, $options{timeout});
}

# Run file watcher example (internal with timeout parameter)
sub run_file_watcher_example_internal {
    my ($example_name, $timeout) = @_;

    unless ($has_ipc_run) {
        return (undef, "SKIP: Missing required module (IPC::Run)");
    }

    # Handle '.' or absolute paths directly, otherwise prepend examples_dir
    my $dir;
    if ($example_name eq '.' || File::Spec->file_name_is_absolute($example_name)) {
        $dir = $example_name;
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }

    my $test_file = "/tmp/aro_test_$$.txt";

    # Start watcher in background (use timeout parameter)
    # Use absolute path to aro binary (works even when cwd changes)
    my $aro_bin = File::Spec->catfile($RealBin, '.build', 'release', 'aro');
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        IPC::Run::start([$aro_bin, 'run', $dir], \$in, \$out, \$err, IPC::Run::timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start file watcher: $@");
    }

    # Register cleanup
    my $cleanup = sub {
        eval {
            kill 'TERM', $handle->pid if $handle->pumpable;
            sleep 0.5;
            IPC::Run::kill_kill($handle) if $handle->pumpable;
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

    # Capture output
    eval { IPC::Run::finish($handle, IPC::Run::timeout(2)) };

    # Cleanup
    $cleanup->();
    @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;

    return ($out, undef);
}

# Run test for a single example
sub run_test {
    my ($example_name) = @_;

    # Read test hints
    my $hints = read_test_hint($example_name);

    # Handle skip directive
    if (defined $hints->{skip}) {
        return {
            name => $example_name,
            type => 'UNKNOWN',
            status => 'SKIP',
            message => "Skipped: $hints->{skip}",
            duration => 0,
        };
    }

    # Use type from hints or auto-detect
    my $type = $hints->{type} || detect_example_type($example_name);

    # Use timeout from hints or default
    my $timeout = $hints->{timeout} // $options{timeout};

    my $start_time = time;

    say "Testing $example_name ($type)..." if $options{verbose};

    # Execute with workdir and pre-script support
    my ($output, $error) = run_test_in_workdir(
        $example_name,
        $hints->{workdir},
        $timeout,
        $type,
        $hints->{'pre-script'}
    );

    my $duration = time - $start_time;

    if ($error) {
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
                : File::Spec->catdir($RealBin, $hints->{workdir});
            chdir $abs_workdir if -d $abs_workdir;
        }

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
            return {
                name => $example_name,
                type => $type,
                status => 'FAIL',
                message => "Test script failed (exit $exit_code)" . ($test_err ? ": $test_err" : ""),
                duration => $duration,
                actual => $test_err,
            };
        }
    }

    # Normalize output
    $output = normalize_output($output, $type);

    # Compare with expected output
    my $expected_file = File::Spec->catfile($examples_dir, $example_name, 'expected.txt');

    unless (-f $expected_file) {
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
    $expected = normalize_output($expected, $type);

    # Choose validation method based on occurrence-check directive
    if (defined $hints->{'occurrence-check'} && $hints->{'occurrence-check'} eq 'true') {
        # Use occurrence-based validation (order-independent)
        my ($all_found, $missing_ref) = check_output_occurrences($output, $expected);

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
            my $diff = '';
            if ($options{verbose}) {
                $diff = "\nExpected:\n$expected\n\nActual:\n$output\n";
            }
            return {
                name => $example_name,
                type => $type,
                status => 'FAIL',
                message => "Missing " . scalar(@missing) . " expected line(s)$diff",
                duration => $duration,
                expected => $expected,
                actual => $output,
                diff => "Missing lines:\n" . join("\n", map { "  - $_" } @missing),
            };
        }
    } else {
        # Use exact string comparison (current behavior)
        if ($output eq $expected) {
            return {
                name => $example_name,
                type => $type,
                status => 'PASS',
                message => '',
                duration => $duration,
            };
        } else {
            my $diff = '';
            if ($options{verbose}) {
                $diff = "\nExpected:\n$expected\n\nActual:\n$output\n";
            }
            return {
                name => $example_name,
                type => $type,
                status => 'FAIL',
                message => "Output mismatch$diff",
                duration => $duration,
            };
        }
    }
}

# Generate expected output for an example
sub generate_expected {
    my ($example_name) = @_;

    # Read test hints
    my $hints = read_test_hint($example_name);

    # Skip if requested
    if (defined $hints->{skip}) {
        say "Skipping $example_name: $hints->{skip}";
        return;
    }

    # Use type from hints or auto-detect
    my $type = $hints->{type} || detect_example_type($example_name);

    # Use timeout from hints or default
    my $timeout = $hints->{timeout} // $options{timeout};

    my $expected_file = File::Spec->catfile($examples_dir, $example_name, 'expected.txt');

    say "Generating expected output for $example_name ($type)...";

    # Execute with workdir and pre-script support
    my ($output, $error) = run_test_in_workdir(
        $example_name,
        $hints->{workdir},
        $timeout,
        $type,
        $hints->{'pre-script'}
    );

    if ($error) {
        warn colored("  ✗ Failed: $error\n", 'red');
        return;
    }

    # Normalize output before saving
    $output = normalize_output($output, $type);

    # Write with enhanced metadata header
    open my $fh, '>', $expected_file or die "Cannot write $expected_file: $!";
    print $fh "# Generated: " . localtime() . "\n";
    print $fh "# Type: $type\n";
    print $fh "# Command: aro run ./Examples/$example_name\n";

    # Add note if test-script is used (output not used for verification)
    if (defined $hints->{'test-script'}) {
        print $fh "# NOTE: This example uses test-script for verification\n";
        print $fh "# This expected.txt is for reference only, not used in testing\n";
    }

    # Add optional metadata from hints
    if (defined $hints->{workdir}) {
        print $fh "# Workdir: $hints->{workdir}\n";
    }

    if (defined $hints->{timeout} && $hints->{timeout} != $options{timeout}) {
        print $fh "# Timeout: $hints->{timeout}s\n";
    }

    print $fh "---\n";
    print $fh $output;
    close $fh;

    say colored("  ✓ Generated $expected_file\n", 'green');
}

# Generate all expected outputs
sub generate_all_expected {
    my ($examples) = @_;

    my $total = scalar @$examples;
    my $current = 0;

    for my $example (@$examples) {
        $current++;
        say sprintf("[%d/%d] %s", $current, $total, $example);

        eval {
            generate_expected($example);
        };
        if ($@) {
            warn colored("  ✗ Error: $@\n", 'red');
        }

        # Prevent overwhelming the system
        sleep 0.5;
    }

    say "\nGeneration complete. $current expected files created/updated.";
}

# Run all tests
sub run_all_tests {
    my ($examples) = @_;

    my $total = scalar @$examples;
    my $current = 0;
    my @results;

    my $start_time = time;

    for my $example (@$examples) {
        $current++;
        print sprintf("[%d/%d] %s... ", $current, $total, $example) unless $options{verbose};

        my $result = run_test($example);
        push @results, $result;

        unless ($options{verbose}) {
            my $status = $result->{status};
            if ($status eq 'PASS') {
                say colored('PASS', 'green');
            } elsif ($status eq 'FAIL') {
                say colored('FAIL', 'red');
            } elsif ($status eq 'SKIP') {
                say colored('SKIP', 'yellow');
            } else {
                say colored('ERROR', 'red');
            }
        }
    }

    my $total_duration = time - $start_time;

    # Print summary
    print_summary(\@results, $total_duration);

    # Exit code
    my $failed = grep { $_->{status} eq 'FAIL' || $_->{status} eq 'ERROR' } @results;
    exit($failed > 0 ? 1 : 0);
}

# Print test summary
sub print_summary {
    my ($results, $duration) = @_;

    my $total = scalar @$results;
    my $passed = grep { $_->{status} eq 'PASS' } @$results;
    my $failed = grep { $_->{status} eq 'FAIL' } @$results;
    my $skipped = grep { $_->{status} eq 'SKIP' } @$results;
    my $errors = grep { $_->{status} eq 'ERROR' } @$results;

    print "\n";
    print "=" x 80 . "\n";
    print "TEST SUMMARY\n";
    print "=" x 80 . "\n";
    printf "%-30s | %-8s | %-8s | %-8s\n", "Example", "Type", "Status", "Duration";
    print "-" x 80 . "\n";

    for my $result (@$results) {
        my $status = $result->{status};
        my $colored_status =
            $status eq 'PASS' ? colored($status, 'green') :
            $status eq 'FAIL' ? colored($status, 'red') :
            $status eq 'SKIP' ? colored($status, 'yellow') :
            colored($status, 'red');

        printf "%-30s | %-8s | %-8s | %.2fs\n",
            $result->{name},
            $result->{type},
            $colored_status,
            $result->{duration};
    }

    print "=" x 80 . "\n";
    printf "SUMMARY: %d/%d passed (%.1f%%)\n",
        $passed,
        $total,
        $total ? 100 * $passed / $total : 0;
    print "  Passed:  " . colored($passed, 'green') . "\n";
    print "  Failed:  " . colored($failed, $failed > 0 ? 'red' : 'green') . "\n";
    print "  Skipped: " . colored($skipped, 'yellow') . "\n";
    print "  Errors:  " . colored($errors, $errors > 0 ? 'red' : 'green') . "\n";
    printf "  Duration: %.2fs\n", $duration;
    print "=" x 80 . "\n";
}

# Run main
main();
