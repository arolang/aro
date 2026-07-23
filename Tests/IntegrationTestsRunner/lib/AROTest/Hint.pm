package AROTest::Hint;

# Parsing of per-example test.hint metadata, plus the testrun.log writer used
# to record build/run failures for CI artifact collection. Extracted verbatim
# from test-examples.pl.

use strict;
use warnings;
use v5.30;
use File::Spec;
use Exporter 'import';

use AROTest::Config qw(%options $examples_dir);

our @EXPORT_OK = qw(read_test_hint write_testrun_log);

# Append a structured failure record to the example's testrun.log. CI
# uploads these as artifacts so a developer can diagnose without re-running
# the whole job locally.
sub write_testrun_log {
    my ($example_name, $mode, $error_type, $message, $cmd, $exit_code) = @_;

    my $log_file = File::Spec->catfile($examples_dir, $example_name, 'testrun.log');

    if (open my $fh, '>>', $log_file) {
        my $timestamp = localtime();
        print $fh "=" x 80 . "\n";
        print $fh "Timestamp: $timestamp\n";
        print $fh "Mode: $mode\n";
        print $fh "Error Type: $error_type\n";
        print $fh "Command: $cmd\n" if $cmd;
        print $fh "Exit Code: $exit_code\n" if defined $exit_code;
        print $fh "Message:\n$message\n";
        print $fh "=" x 80 . "\n\n";
        close $fh;
    } else {
        warn "Warning: Could not write to $log_file: $!\n" if $options{verbose};
    }
}

# Read test.hint for an example. Returns a hashref of recognised directives,
# all preset to undef when missing. Unknown keys produce a warning under
# --verbose; bad type / mode values are reset to undef (or 'both' for mode).
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
        'skip-on-macos' => undef,
        'skip-on-ci' => undef,
        'skip-compiled-on-linux' => undef,
        'pre-script' => undef,
        'test-script' => undef,
        'occurrence-check' => undef,
        'keep-alive' => undef,
        'allow-error' => undef,
        'skip-build' => undef,
        'normalize-dict' => undef,
        'strip-prefix' => undef,
        'random-output' => undef,
        'include-server-output' => undef,
        'request-delay' => undef,
    );

    return \%hints unless -f $hint_file;

    open my $fh, '<', $hint_file or do {
        warn "Warning: Cannot read $hint_file: $!\n" if $options{verbose};
        return \%hints;
    };

    my $line_no = 0;
    while (my $line = <$fh>) {
        $line_no++;
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if !$line || $line =~ /^#/;

        if ($line =~ /^([^:]+):\s*(.*)$/) {
            my $key = lc $1;
            my $value = $2;
            $value =~ s/^\s+|\s+$//g;

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

    if (defined $hints{timeout} && $hints{timeout} !~ /^\d+$/) {
        warn "Warning: Invalid timeout value '$hints{timeout}' (must be integer), ignoring\n";
        $hints{timeout} = undef;
    }

    if (defined $hints{type} && $hints{type} !~ /^(console|http|socket|socket-client|file|multi-context|multiservice)$/) {
        warn "Warning: Invalid type '$hints{type}' (must be console|http|socket|socket-client|file|multi-context|multiservice), ignoring\n";
        $hints{type} = undef;
    }

    if (defined $hints{mode} && $hints{mode} !~ /^(both|interpreter|compiled|test)$/) {
        warn "Warning: Invalid mode '$hints{mode}' (must be both|interpreter|compiled|test), defaulting to 'both'\n";
        $hints{mode} = 'both';
    }

    return \%hints;
}

1;
