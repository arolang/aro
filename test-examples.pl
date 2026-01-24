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
use List::Util qw(sum all);

# Required modules
use IPC::Run qw(start finish timeout kill_kill);

# Try to load optional modules, fall back to basic functionality if not available
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

# Platform detection
my $is_windows = ($^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys');
my $is_linux = ($^O eq 'linux');
my $is_macos = ($^O eq 'darwin');

# Get binary path with proper extension for the platform
# On Windows, executables have .exe extension
sub get_binary_path {
    my ($dir, $basename) = @_;
    my $binary_name = $is_windows ? "$basename.exe" : $basename;
    return File::Spec->catfile($dir, $binary_name);
}

# Check if a file is executable (cross-platform)
# On Windows, -x doesn't work reliably, so we check for .exe extension
sub is_executable {
    my ($path) = @_;
    if ($is_windows) {
        # On Windows, check if the file exists and has .exe extension
        return (-e $path && $path =~ /\.exe$/i);
    } else {
        return -x $path;
    }
}

# Configuration
my %options = (
    generate => 0,
    verbose => 0,
    timeout => 60,  # Increased for Linux CI linker (default was 10)
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
    --timeout=N         Timeout in seconds for long-running examples (default: 60)
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

# Write to testrun.log in example directory
sub write_testrun_log {
    my ($example_name, $mode, $error_type, $message, $cmd, $exit_code) = @_;

    my $log_file = File::Spec->catfile($examples_dir, $example_name, 'testrun.log');

    # Open in append mode to preserve multiple test runs
    if (open my $fh, '>>', $log_file) {
        my $timestamp = localtime();
        print $fh "=" x 80 . "\n";
        print $fh "Timestamp: $timestamp\n";
        print $fh "Mode: $mode\n";
        print $fh "Error Type: $error_type\n";
        if ($cmd) {
            print $fh "Command: $cmd\n";
        }
        if (defined $exit_code) {
            print $fh "Exit Code: $exit_code\n";
        }
        print $fh "Message:\n$message\n";
        print $fh "=" x 80 . "\n\n";
        close $fh;
    } else {
        warn "Warning: Could not write to $log_file: $!\n" if $options{verbose};
    }
}

# Main execution
sub main {
    unless (-d $examples_dir) {
        die "Examples directory not found: $examples_dir\n";
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

    # Directories to exclude from testing
    my %excluded = (
        'template' => 1,     # Template directory
        'data' => 1,         # Test output directory
        'output' => 1,       # Test output directory
        'demo-output' => 1,  # Test output directory
    );

    my @examples = grep {
        -d File::Spec->catdir($examples_dir, $_) &&
        !/^\./ &&
        !$excluded{$_}
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
        mode => undef,
        skip => undef,
        'skip-on-windows' => undef,
        'skip-on-linux' => undef,
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

    if (defined $hints{mode} && $hints{mode} !~ /^(both|interpreter|compiled|test)$/) {
        warn "Warning: Invalid mode '$hints{mode}' (must be both|interpreter|compiled|test), defaulting to 'both'\n";
        $hints{mode} = 'both';
    }

    return \%hints;
}

# Find the aro binary - checks environment variable, then local build, then installed versions
sub find_aro_binary {
    my $exe_ext = $is_windows ? '.exe' : '';

    # 1. Check if ARO_BIN environment variable is set
    if ($ENV{ARO_BIN} && is_executable($ENV{ARO_BIN})) {
        return $ENV{ARO_BIN};
    }

    # 2. Check local release build first (most up-to-date during development)
    my $local_release = File::Spec->catfile($RealBin, '.build', 'release', "aro$exe_ext");
    if (is_executable($local_release)) {
        return $local_release;
    }

    if (!$is_windows) {
        # 3. Check /usr/bin/aro (system install) - Unix only
        if (-x '/usr/bin/aro') {
            return '/usr/bin/aro';
        }

        # 4. Check /opt/homebrew/bin/aro (Homebrew on Apple Silicon)
        if (-x '/opt/homebrew/bin/aro') {
            return '/opt/homebrew/bin/aro';
        }
    }

    # 5. Check ./aro-bin/aro (local binary directory - used in CI)
    my $local_bin = File::Spec->catfile($RealBin, 'aro-bin', "aro$exe_ext");
    if (is_executable($local_bin)) {
        return $local_bin;
    }

    # 6. Last resort: try 'aro' in PATH and let shell find it
    my $which_cmd = $is_windows ? "where aro$exe_ext 2>nul" : "which aro 2>/dev/null";
    my $which_aro = `$which_cmd`;
    chomp $which_aro;
    # On Windows, 'where' can return multiple lines; take the first
    ($which_aro) = split /\n/, $which_aro if $which_aro;
    if ($which_aro && is_executable($which_aro)) {
        return $which_aro;
    }

    # Fallback: return 'aro' and hope for the best
    return 'aro';
}

# Build an example using 'aro build'
# Returns hash with success status, binary path, error message, and build duration
sub build_example {
    my ($example_name, $timeout, $workdir) = @_;

    # Use workdir if specified, otherwise use example_name
    my $dir;
    if (defined $workdir) {
        # Convert relative workdir to absolute path
        if (File::Spec->file_name_is_absolute($workdir)) {
            $dir = $workdir;
        } else {
            $dir = File::Spec->catdir($RealBin, $workdir);
        }
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }
    my $aro_bin = find_aro_binary();

    my $start_time = time;

    # Execute: aro build <dir>
    # Use --keep-intermediate to preserve LLVM IR for debugging failures
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        start(
            [$aro_bin, 'build', $dir, '--keep-intermediate'],
            \$in, \$out, \$err,
            timeout($timeout)
        );
    };

    if ($@) {
        my $error_msg = "Build failed to start: $@";
        write_testrun_log($example_name, 'compiled', 'BUILD_START_FAILURE', $error_msg, "$aro_bin build $dir", undef);
        return {
            success => 0,
            error => $error_msg,
            duration => 0,
        };
    }

    eval { finish($handle) };
    my $build_duration = time - $start_time;

    if ($? != 0) {
        my $combined_err = $err || $out;
        my $exit_code = $? >> 8;
        my $error_msg = "Build failed: $combined_err";
        write_testrun_log($example_name, 'compiled', 'BUILD_FAILURE', $error_msg, "$aro_bin build $dir", $exit_code);
        return {
            success => 0,
            error => $error_msg,
            duration => $build_duration,
        };
    }

    # Check if binary exists
    my $basename = basename($dir);
    my $binary_path = get_binary_path($dir, $basename);

    unless (is_executable($binary_path)) {
        # Include build output in error message for debugging
        my $build_output = $out || $err || "(no output)";
        my $error_msg = "Binary not found at: $binary_path\n\nBuild output:\n$build_output";
        write_testrun_log($example_name, 'compiled', 'BINARY_NOT_FOUND', $error_msg, "$aro_bin build $dir", 0);
        return {
            success => 0,
            error => $error_msg,
            duration => $build_duration,
        };
    }

    return {
        success => 1,
        binary_path => $binary_path,
        duration => $build_duration,
    };
}

# Run test with specified working directory
# Handles chdir, executes appropriate test runner, restores original directory
sub run_test_in_workdir {
    my ($example_name, $workdir, $timeout, $type, $pre_script, $mode) = @_;
    $mode //= 'interpreter';  # Default to interpreter mode

    my $orig_cwd = cwd();
    my $output;
    my $error;
    my $run_dir = $example_name;  # Default: use example name as-is
    my $binary_name;  # For compiled mode when using workdir

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
        # Use workdir's directory name for finding compiled binary (e.g., Combined from Examples/ModulesExample/Combined)
        $binary_name = basename($abs_workdir);
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
    # Pass $binary_name for compiled mode when using workdir
    if ($type eq 'console') {
        ($output, $error) = run_console_example_internal($run_dir, $timeout, $mode, $binary_name);
    } elsif ($type eq 'http') {
        ($output, $error) = run_http_example_internal($run_dir, $timeout, $mode, $binary_name);
    } elsif ($type eq 'socket') {
        ($output, $error) = run_socket_example_internal($run_dir, $timeout, $mode, $binary_name);
    } elsif ($type eq 'file') {
        ($output, $error) = run_file_watcher_example_internal($run_dir, $timeout, $mode, $binary_name);
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

    # Use IPC::Run for timeout support
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        start(['sh', '-c', $script], \$in, \$out, \$err,
              timeout($timeout));
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

    # Remove ANSI escape codes (colors, bold, etc.)
    $output =~ s/\e\[[0-9;]*m//g;

    # Remove Objective-C duplicate class warnings (macOS Swift runtime conflicts)
    # These occur when both system Swift and toolchain Swift runtimes are loaded
    # Example: objc[12345]: Class _TtCs27_KeyedEncodingContainerBase is implemented in both ...
    $output =~ s/^objc\[\d+\]: Class .* is implemented in both .* One of the duplicates must be removed or renamed\.\n//gm;

    # Remove timing values from test output (e.g., "(1ms)", "(<1ms)")
    $output =~ s/\s*\([<]?\d+m?s\)//g;

    # Remove leading whitespace from lines (test output has indentation)
    $output =~ s/^[ \t]+//gm;

    # Remove bracketed prefixes at start of lines (e.g., [Application-Start], [OK], etc.)
    # Binary applications don't output these, only the interpreter does
    # Pattern: [LetterFollowedByAlphanumericSpacesHyphens] at line start
    # This avoids matching JSON-like brackets in content (e.g., ["data": "value"])
    # Use [ \t]* instead of \s* to preserve newlines (blank lines from empty Log statements)
    $output =~ s/^\[[A-Za-z][A-Za-z0-9 -]*\][ \t]*//gm;

    # Remove ISO timestamps
    $output =~ s/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?/__TIMESTAMP__/g;

    # Normalize ls -la timestamps (month day time/year before filename)
    # Matches: "Jan  3 12:26" or "Dec 31  2025" in ls output
    $output =~ s/^([\-dlrwxs@+]+\s+\d+\s+\w+\s+\w+\s+\d+\s+)\w+\s+\d+\s+[\d:]+/$1__DATE__/gm;

    # Normalize ls -la total blocks count
    $output =~ s/listing\.output: total \d+/listing.output: total __TOTAL__/g;

    # Normalize API response times (generationtime_ms from weather API)
    $output =~ s/generationtime_ms: \d+\.\d+/generationtime_ms: __TIME__/g;

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

# Convert expected output with placeholders to regex pattern
# Supports: __ID__, __UUID__, __TIMESTAMP__, __DATE__, __NUMBER__, __STRING__
# Each pattern also matches the literal placeholder (for normalized output comparison)
sub expected_to_pattern {
    my ($expected) = @_;

    # Escape regex metacharacters in the expected string
    my $pattern = quotemeta($expected);

    # Replace escaped placeholders with actual regex patterns
    # Each pattern matches either the dynamic value OR the literal placeholder
    # (since normalize_output may have replaced values with placeholders)

    # __ID__ - matches hex IDs like 19b8607cf80ae931b1f (timestamp + random)
    $pattern =~ s/__ID__/(?:[a-f0-9]{15,20}|__ID__)/g;

    # __UUID__ - matches UUIDs like 550e8400-e29b-41d4-a716-446655440000
    $pattern =~ s/__UUID__/(?:[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}|__UUID__)/g;

    # __TIMESTAMP__ - matches ISO timestamps like 2025-01-03T23:43:37.478982169+01:00 or 2026-01-03T22:45
    $pattern =~ s/__TIMESTAMP__/(?:\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}(?::\\d{2})?(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})?|__TIMESTAMP__)/g;

    # __DATE__ - matches dates like Jan 3 23:43 or 2025-01-03 (already used in DirectoryLister)
    $pattern =~ s/__DATE__/(?:\\w{3}\\s+\\d{1,2}\\s+\\d{2}:\\d{2}|\\d{4}-\\d{2}-\\d{2}|__DATE__)/g;

    # __NUMBER__ - matches any number (integer or decimal)
    $pattern =~ s/__NUMBER__/(?:-?\\d+(?:\\.\\d+)?|__NUMBER__)/g;

    # __STRING__ - matches any non-empty string (non-greedy, no quotes)
    $pattern =~ s/__STRING__/(?:.+?|__STRING__)/g;

    # __HASH__ - matches hash values (32-64 hex chars) - already used in HashTest
    $pattern =~ s/__HASH__/(?:[a-f0-9]{32,64}|__HASH__)/g;

    # __TOTAL__ - matches total blocks count in ls output
    $pattern =~ s/__TOTAL__/(?:\\d+|__TOTAL__)/g;

    # __TIME__ - matches decimal time values like generationtime_ms (0.08, 1.23)
    $pattern =~ s/__TIME__/(?:\\d+\\.\\d+|__TIME__)/g;

    return $pattern;
}

# Automatically replace dynamic values with placeholders for --generate
sub auto_placeholderize {
    my ($output, $type) = @_;

    # For HTTP tests, replace hex IDs with __ID__
    if ($type && $type eq 'http') {
        # Replace hex IDs (15-20 chars) in JSON id fields
        $output =~ s/"id":"[a-f0-9]{15,20}"/"id":"__ID__"/g;
    }

    # Replace ISO timestamps (with or without seconds, timezone)
    $output =~ s/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?/__TIMESTAMP__/g;

    # For console tests with weather/API data, replace numbers in specific contexts
    if ($type && $type eq 'console') {
        # Replace generationtime_ms with __TIME__ (special case)
        $output =~ s/generationtime_ms:\s*\d+\.\d+/generationtime_ms: __TIME__/g;

        # Replace numbers after "temperature:", "windspeed:", etc. (weather data)
        $output =~ s/(temperature|windspeed|winddirection|elevation|latitude|longitude|is_day|weathercode):\s*-?\d+(?:\.\d+)?/$1: __NUMBER__/g;
    }

    return $output;
}

# Check if actual output matches expected pattern (with placeholder support)
sub matches_pattern {
    my ($actual, $expected) = @_;

    # Split into lines for line-by-line comparison
    my @actual_lines = split /\n/, $actual;
    my @expected_lines = split /\n/, $expected;

    # Must have same number of lines
    return 0 if scalar(@actual_lines) != scalar(@expected_lines);

    # Check each line
    for (my $i = 0; $i < scalar(@expected_lines); $i++) {
        my $expected_line = $expected_lines[$i];
        my $actual_line = $actual_lines[$i];

        # Convert expected line to pattern
        my $pattern = expected_to_pattern($expected_line);

        # Check if actual line matches pattern
        unless ($actual_line =~ /^$pattern$/) {
            return 0;
        }
    }

    # All lines matched
    return 1;
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

        # Use expected_to_pattern to convert placeholders like __NUMBER__, __TIMESTAMP__, etc.
        my $pattern = expected_to_pattern($expected_line);

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

    # Use IPC::Run for better control
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        start(\@cmd, \$in, \$out, \$err, timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start: $@");
    }

    eval {
        finish($handle);
    };

    if ($@) {
        if ($@ =~ /timeout/) {
            kill_kill($handle);
            return (undef, "TIMEOUT after ${timeout}s");
        }
        return (undef, "ERROR: $@");
    }

    # Combine stdout and stderr
    my $combined = $out;
    $combined .= $err if $err;
    return ($combined, undef);
}

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
    my ($example_name, $timeout, $mode, $binary_name) = @_;
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

    # Extract port
    my $port = 8080;
    if ($spec->{servers} && $spec->{servers}[0]{url}) {
        my $url = $spec->{servers}[0]{url};
        $port = $1 if $url =~ /:(\d+)/;
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

    # Start server in background
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
    my $http = HTTP::Tiny->new(timeout => 5);
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
        @operations = sort {
            ($a->{order} // 50) <=> ($b->{order} // 50) ||
            (!$a->{has_params}) <=> (!$b->{has_params}) ||
            $a->{path} cmp $b->{path}
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
                        next unless $param->{in} eq 'query';
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

                my $response;
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
                    next;
                }

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
                } else {
                    push @output, sprintf("%s %s => ERROR: No response", uc($method), $path);
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

# Run file watcher example (public interface)
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

    my $test_file = "/tmp/aro_test_$$.txt";

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

    # Capture output
    eval { finish($handle, timeout(2)) };

    # Cleanup
    $cleanup->();
    @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;

    # Combine stdout and stderr
    my $combined = $out;
    $combined .= $err if $err;
    return ($combined, undef);
}

# Run test for a single example in a specific mode
sub run_single_mode_test {
    my ($example_name, $hints, $type, $timeout, $mode) = @_;

    my $start_time = time;

    say "  Testing $example_name in $mode mode..." if $options{verbose};

    # Execute with workdir and pre-script support
    my ($output, $error) = run_test_in_workdir(
        $example_name,
        $hints->{workdir},
        $timeout,
        $type,
        $hints->{'pre-script'},
        $mode
    );

    my $duration = time - $start_time;

    if ($error) {
        # Log execution errors (not skips)
        unless ($error =~ /^SKIP/) {
            my $error_type = $error =~ /TIMEOUT/ ? 'TIMEOUT' :
                            $error =~ /Exit code/ ? 'EXECUTION_FAILURE' : 'ERROR';
            write_testrun_log($example_name, $mode, $error_type, $error, undef, undef);
        }
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
            my $error_msg = "Test script failed (exit $exit_code)" . ($test_err ? ": $test_err" : "");
            write_testrun_log($example_name, $mode, 'TEST_SCRIPT_FAILURE', $error_msg, $hints->{'test-script'}, $exit_code);
            return {
                name => $example_name,
                type => $type,
                status => 'FAIL',
                message => $error_msg,
                duration => $duration,
                actual => $test_err,
            };
        }
    }

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

    # Trim whitespace from both (without other normalization for pattern matching)
    my $output_for_comparison = $output;
    my $expected_for_comparison = $expected;
    $output_for_comparison =~ s/^\s+|\s+$//g;
    $output_for_comparison =~ s/ +$//gm;  # Remove trailing spaces from lines
    $expected_for_comparison =~ s/^\s+|\s+$//g;
    $expected_for_comparison =~ s/ +$//gm;

    # Choose validation method based on occurrence-check directive
    if (defined $hints->{'occurrence-check'} && $hints->{'occurrence-check'} eq 'true') {
        # Use occurrence-based validation (order-independent)
        # For occurrence check, we need normalized output
        my $output_normalized = normalize_output($output, $type);
        my $expected_normalized = normalize_output($expected, $type);

        my ($all_found, $missing_ref) = check_output_occurrences($output_normalized, $expected_normalized);

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
                $diff = "\nExpected:\n$expected_normalized\n\nActual:\n$output_normalized\n";
            }
            my $error_msg = "Missing " . scalar(@missing) . " expected line(s)$diff";
            my $full_error = $error_msg . "\nMissing lines:\n" . join("\n", map { "  - $_" } @missing);
            write_testrun_log($example_name, $mode, 'OUTPUT_MISMATCH', $full_error, undef, undef);
            return {
                name => $example_name,
                type => $type,
                status => 'FAIL',
                message => $error_msg,
                duration => $duration,
                expected => $expected_normalized,
                actual => $output_normalized,
                diff => "Missing lines:\n" . join("\n", map { "  - $_" } @missing),
            };
        }
    } else {
        # Use pattern matching for comparison (supports __ID__, __UUID__, etc.)
        # Normalize both to remove brackets and other dynamic content
        my $output_normalized = normalize_output($output, $type);
        my $expected_normalized = normalize_output($expected, $type);

        # Trim whitespace after normalization
        $output_normalized =~ s/^\s+|\s+$//g;
        $output_normalized =~ s/ +$//gm;
        $expected_normalized =~ s/^\s+|\s+$//g;
        $expected_normalized =~ s/ +$//gm;

        if (matches_pattern($output_normalized, $expected_normalized)) {
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
                $diff = "\nExpected:\n$expected_normalized\n\nActual:\n$output_normalized\n";
            }
            my $error_msg = "Output mismatch$diff";
            write_testrun_log($example_name, $mode, 'OUTPUT_MISMATCH', $error_msg, undef, undef);
            return {
                name => $example_name,
                type => $type,
                status => 'FAIL',
                message => $error_msg,
                duration => $duration,
                expected => $expected_normalized,
                actual => $output_normalized,
                expected_file => $expected_file,
            };
        }
    }
}

# Run test for a single example (dual-mode orchestration)
sub run_test {
    my ($example_name) = @_;

    # Delete old diff files and testrun.log if they exist
    my $diff_file = "Examples/$example_name/expected.diff";
    my $binary_diff_file = "Examples/$example_name/expected.binary.diff";
    my $log_file = "Examples/$example_name/testrun.log";
    unlink $diff_file if -f $diff_file;
    unlink $binary_diff_file if -f $binary_diff_file;
    unlink $log_file if -f $log_file;

    # Read test hints
    my $hints = read_test_hint($example_name);

    # Handle skip directive (applies to both modes)
    if (defined $hints->{skip}) {
        return {
            name => $example_name,
            type => 'UNKNOWN',
            interpreter_status => 'SKIP',
            compiled_status => 'SKIP',
            interpreter_message => "Skipped: $hints->{skip}",
            compiled_message => "Skipped: $hints->{skip}",
            interpreter_duration => 0,
            compiled_duration => 0,
            build_duration => 0,
            avg_duration => 0,
            status => 'SKIP',
            duration => 0,
        };
    }

    # Handle Windows-specific skip
    if ($is_windows && defined $hints->{'skip-on-windows'}) {
        return {
            name => $example_name,
            type => 'UNKNOWN',
            interpreter_status => 'SKIP',
            compiled_status => 'SKIP',
            interpreter_message => "Skipped on Windows: $hints->{'skip-on-windows'}",
            compiled_message => "Skipped on Windows: $hints->{'skip-on-windows'}",
            interpreter_duration => 0,
            compiled_duration => 0,
            build_duration => 0,
            avg_duration => 0,
            status => 'SKIP',
            duration => 0,
        };
    }

    # Handle Linux-specific skip
    if ($is_linux && defined $hints->{'skip-on-linux'}) {
        return {
            name => $example_name,
            type => 'UNKNOWN',
            interpreter_status => 'SKIP',
            compiled_status => 'SKIP',
            interpreter_message => "Skipped on Linux: $hints->{'skip-on-linux'}",
            compiled_message => "Skipped on Linux: $hints->{'skip-on-linux'}",
            interpreter_duration => 0,
            compiled_duration => 0,
            build_duration => 0,
            avg_duration => 0,
            status => 'SKIP',
            duration => 0,
        };
    }

    # Determine test mode
    my $mode = $hints->{mode} // 'both';
    my $type = $hints->{type} || detect_example_type($example_name);
    my $timeout = $hints->{timeout} // $options{timeout};

    say "Testing $example_name ($type) in $mode mode..." if $options{verbose};

    # Initialize result
    my $result = {
        name => $example_name,
        type => $type,
        interpreter_status => 'N/A',
        compiled_status => 'N/A',
        interpreter_message => '',
        compiled_message => '',
        interpreter_duration => 0,
        compiled_duration => 0,
        build_duration => 0,
        avg_duration => 0,
    };

    # Run interpreter test
    if ($mode eq 'interpreter' || $mode eq 'both' || $mode eq 'test') {
        my $test_mode = $mode eq 'test' ? 'test' : 'interpreter';
        my $interp_result = run_single_mode_test(
            $example_name, $hints, $type, $timeout, $test_mode
        );

        $result->{interpreter_status} = $interp_result->{status};
        $result->{interpreter_duration} = $interp_result->{duration};
        $result->{interpreter_message} = $interp_result->{message} // '';
        $result->{interpreter_expected} = $interp_result->{expected};
        $result->{interpreter_actual} = $interp_result->{actual};
    }

    # Run compiled test
    if ($mode eq 'compiled' || $mode eq 'both') {
        # Build the example first (use workdir if specified)
        my $build_result = build_example($example_name, $timeout, $hints->{workdir});
        $result->{build_duration} = $build_result->{duration};

        if (!$build_result->{success}) {
            # Build failed - mark as ERROR
            $result->{compiled_status} = 'ERROR';
            $result->{compiled_message} = $build_result->{error};
            $result->{compiled_duration} = 0;
        } else {
            # Build succeeded - run compiled test
            my $compiled_result = run_single_mode_test(
                $example_name, $hints, $type, $timeout, 'compiled'
            );

            $result->{compiled_status} = $compiled_result->{status};
            $result->{compiled_duration} = $compiled_result->{duration};
            $result->{compiled_message} = $compiled_result->{message} // '';
            $result->{compiled_expected} = $compiled_result->{expected};
            $result->{compiled_actual} = $compiled_result->{actual};
        }
    }

    # Calculate averages and overall status
    my @durations = grep { $_ > 0 } (
        $result->{interpreter_duration},
        $result->{compiled_duration}
    );
    $result->{avg_duration} = @durations ? (sum(@durations) / @durations) : 0;

    # Overall status: PASS only if both tested modes passed
    my @statuses = grep { $_ ne 'N/A' } (
        $result->{interpreter_status},
        $result->{compiled_status}
    );

    if (grep { $_ eq 'FAIL' || $_ eq 'ERROR' } @statuses) {
        $result->{status} = 'FAIL';
    } elsif (grep { $_ eq 'SKIP' } @statuses) {
        $result->{status} = 'SKIP';
    } elsif (@statuses > 0 && all { $_ eq 'PASS' } @statuses) {
        $result->{status} = 'PASS';
    } else {
        $result->{status} = 'ERROR';
    }

    $result->{duration} = $result->{avg_duration};

    return $result;
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

    # Skip on Windows if requested
    if ($is_windows && defined $hints->{'skip-on-windows'}) {
        say "Skipping $example_name on Windows: $hints->{'skip-on-windows'}";
        return;
    }

    # Skip on Linux if requested
    if ($is_linux && defined $hints->{'skip-on-linux'}) {
        say "Skipping $example_name on Linux: $hints->{'skip-on-linux'}";
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

    # Auto-replace dynamic values with placeholders
    $output = auto_placeholderize($output, $type);

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

# Create temporary files for diff comparison
sub create_temp_files {
    my ($result) = @_;

    require File::Temp;
    my $temp_expected = File::Temp->new(SUFFIX => '.expected.txt', UNLINK => 0);
    my $temp_actual = File::Temp->new(SUFFIX => '.actual.txt', UNLINK => 0);

    print $temp_expected $result->{expected};
    print $temp_actual $result->{actual};

    close $temp_expected;
    close $temp_actual;

    return ($temp_expected->filename, $temp_actual->filename);
}

# Create diff file for a failed test (dual-mode support)
sub create_diff_file {
    my ($result) = @_;

    # Only create diff for failures
    return unless $result->{status} eq 'FAIL';

    my $example_name = $result->{name};
    my $expected_file = File::Spec->catfile($examples_dir, $example_name, 'expected.txt');

    # Check interpreter failure
    if ($result->{interpreter_status} && $result->{interpreter_status} eq 'FAIL' &&
        $result->{interpreter_expected} && $result->{interpreter_actual}) {

        my $diff_file = File::Spec->catfile($examples_dir, $example_name, 'expected.diff');

        # Create a temporary result hash in the old format for create_temp_files
        my $temp_result = {
            expected => $result->{interpreter_expected},
            actual => $result->{interpreter_actual},
        };

        my ($temp_expected, $temp_actual) = create_temp_files($temp_result);
        my $diff_output = `diff -u "$temp_expected" "$temp_actual" 2>&1`;

        if (open my $fh, '>', $diff_file) {
            print $fh $diff_output;
            close $fh;
            print "  Created interpreter diff: $diff_file\n" if $options{verbose};
        }

        unlink $temp_expected, $temp_actual;
    }

    # Check compiled binary failure
    if ($result->{compiled_status} && $result->{compiled_status} eq 'FAIL' &&
        $result->{compiled_expected} && $result->{compiled_actual}) {

        my $diff_file = File::Spec->catfile($examples_dir, $example_name, 'expected.binary.diff');

        # Create a temporary result hash in the old format for create_temp_files
        my $temp_result = {
            expected => $result->{compiled_expected},
            actual => $result->{compiled_actual},
        };

        my ($temp_expected, $temp_actual) = create_temp_files($temp_result);
        my $diff_output = `diff -u "$temp_expected" "$temp_actual" 2>&1`;

        if (open my $fh, '>', $diff_file) {
            print $fh $diff_output;
            close $fh;
            print "  Created binary diff: $diff_file\n" if $options{verbose};
        }

        unlink $temp_expected, $temp_actual;
    }
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

    # Create diff files for all failed tests
    for my $result (@results) {
        if ($result->{status} eq 'FAIL') {
            create_diff_file($result);
        }
    }

    # Exit code
    my $failed = grep { $_->{status} eq 'FAIL' || $_->{status} eq 'ERROR' } @results;
    exit($failed > 0 ? 1 : 0);
}

# Print test summary
# Format status with color coding
sub format_status {
    my ($status) = @_;

    return 'N/A' if $status eq 'N/A';

    my %colors = (
        PASS => 'green',
        FAIL => 'red',
        SKIP => 'yellow',
        ERROR => 'red',
    );

    my $color = $colors{$status} // 'white';
    return colored($status, $color);
}

sub print_summary {
    my ($results, $duration) = @_;

    my $total = scalar @$results;
    my $passed = grep { $_->{status} eq 'PASS' } @$results;
    my $failed = grep { $_->{status} ne 'PASS' && $_->{status} ne 'SKIP' } @$results;
    my $skipped = grep { $_->{status} eq 'SKIP' } @$results;

    print "\n";
    print "=" x 120 . "\n";
    print "TEST SUMMARY\n";
    print "=" x 120 . "\n";
    printf "%-30s | %-8s | %-12s | %-12s | %-12s\n",
        "Example", "Type", "Interpreter", "Binary", "Avg Duration";
    print "-" x 120 . "\n";

    for my $result (@$results) {
        # Format statuses with color codes
        my $interp_status = format_status($result->{interpreter_status});
        my $compiled_status = format_status($result->{compiled_status});

        printf "%-30s | %-8s | %-20s | %-20s | %.2fs\n",
            $result->{name},
            $result->{type},
            $interp_status,
            $compiled_status,
            $result->{avg_duration};
    }

    print "=" x 120 . "\n";
    printf "SUMMARY: %d/%d passed (%.1f%%)\n",
        $passed,
        $total,
        $total ? 100 * $passed / $total : 0;
    print "  Passed:  " . colored($passed, 'green') . "\n";
    print "  Failed:  " . colored($failed, $failed > 0 ? 'red' : 'green') . "\n";
    print "  Skipped: " . colored($skipped, 'yellow') . "\n";
    printf "  Duration: %.2fs\n", $duration;
    print "=" x 120 . "\n";
}

# Run main
main();
