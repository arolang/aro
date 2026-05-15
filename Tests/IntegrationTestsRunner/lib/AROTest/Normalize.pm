package AROTest::Normalize;

# Output canonicalisation for comparison against expected.txt. The same
# normalisation is applied to interpreter and compiled outputs so that
# expected.txt only has to match one shape. Lines, regexes, and ordering are
# preserved verbatim from test-examples.pl — output identity is the contract.

use strict;
use warnings;
use v5.30;
use Exporter 'import';

use AROTest::Config qw($project_root);

our @EXPORT_OK = qw(normalize_dict_literals normalize_output _normalize_json_output);

# Sort the key/value pairs inside Swift/ARO dict literals so output ordering
# from `Dictionary.keys` doesn't make tests flaky. Handles quoted-string values
# (incl. embedded commas) and unquoted scalars.
sub normalize_dict_literals {
    my ($output) = @_;

    my @lines = split /\n/, $output;
    my @result_lines;

    for my $line (@lines) {
        if ($line =~ /\[("[^"]+"\s*:.*)\]/) {
            my $before_bracket = $`;
            my $after_bracket = $';
            my $dict_content = $1;
            my @pairs;

            while ($dict_content =~ /"([^"]+)"\s*:\s*("(?:[^"\\]|\\.)*"|[^,\]]+)/g) {
                my $key = $1;
                my $value = $2;
                $value =~ s/\s+$//;
                push @pairs, [$key, $value];
            }

            if (@pairs) {
                @pairs = sort { $a->[0] cmp $b->[0] } @pairs;
                my $sorted = '[' . join(', ', map { qq{"$_->[0]": $_->[1]} } @pairs) . ']';
                $line = $before_bracket . $sorted . $after_bracket;
            }
        }
        push @result_lines, $line;
    }

    return join("\n", @result_lines);
}

# Strip ANSI, timestamps, prompts, and other interpreter-only ornamentation
# so the same expected.txt can match output from both `aro run` and the
# compiled binary. `$type` opts in to extra normalisation (hash, http).
sub normalize_output {
    my ($output, $type) = @_;

    # Remove ANSI escape codes (colors, bold, etc.)
    $output =~ s/\e\[[0-9;]*m//g;

    # Remove macOS Swift dual-runtime warnings.
    $output =~ s/^objc\[\d+\]: Class .* is implemented in both .* One of the duplicates must be removed or renamed\.\n//gm;

    # Remove timing values from test output (e.g., "(1ms)", "(<1ms)")
    $output =~ s/\s*\([<]?\d+m?s\)//g;

    # Remove leading whitespace from lines (test output has indentation)
    $output =~ s/^[ \t]+//gm;

    # Remove bracketed prefixes at start of lines (e.g., [Application-Start], [OK], etc.)
    # Binary applications don't output these, only the interpreter does.
    # Use [ \t]* (not \s*) to preserve newlines from empty Log statements.
    $output =~ s/^\[[A-Za-z][A-Za-z0-9 -]*\][ \t]*//gm;

    # Remove ISO timestamps
    $output =~ s/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?/__TIMESTAMP__/g;

    # Normalize ls -la timestamps (month day time/year before filename).
    $output =~ s/^([\-dlrwxs@+]+\s+\d+\s+\w+\s+\w+\s+\d+\s+)\w+\s+\d+\s+[\d:]+/$1__DATE__/gm;

    # Normalize ls -la total blocks count
    $output =~ s/listing\.output: total \d+/listing.output: total __TOTAL__/g;

    # Normalize API response times (generationtime_ms from weather API)
    $output =~ s/generationtime_ms: \d+\.\d+/generationtime_ms: __TIME__/g;

    # Normalize paths (absolute -> relative). The base dir is the project root
    # so example output is portable across check-out locations.
    my $base_dir = $project_root;
    $output =~ s/\Q$base_dir\E/./g;

    # Normalize line endings
    $output =~ s/\r\n/\n/g;

    # Remove trailing whitespace
    $output =~ s/ +$//gm;

    # Normalize hash values (for HashTest example)
    $output =~ s/\b[a-f0-9]{32,64}\b/__HASH__/g if $type && $type eq 'hash';

    # Normalize floating point numbers with excessive precision in JSON
    # (HTTP responses): 249.99000000000001 -> 249.99
    if ($type && $type eq 'http') {
        $output =~ s/(\d+\.\d{1,2})0{6,}\d+/$1/g;
    }

    return $output;
}

# Multi-context tests record JSON responses; normalise float precision so
# minor encoder differences don't make the test flaky.
sub _normalize_json_output {
    my ($output) = @_;
    $output =~ s/(\d+\.\d{1,2})0{6,}\d+/$1/g;
    return $output;
}

1;
