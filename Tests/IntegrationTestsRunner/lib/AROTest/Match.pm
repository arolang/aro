package AROTest::Match;

# Expected-vs-actual comparison with placeholder support. expected.txt files
# can contain placeholders like __TIMESTAMP__, __UUID__, __NUMBER__ that match
# dynamic values; auto_placeholderize is the inverse, used by --generate to
# detect dynamic values in fresh output and write them as placeholders.

use strict;
use warnings;
use v5.30;
use Exporter 'import';

our @EXPORT_OK = qw(
    expected_to_pattern auto_placeholderize matches_pattern check_output_occurrences
);

# Convert an expected.txt line into a regex. Each placeholder matches either
# the dynamic value OR the literal placeholder string — that second branch
# matters because normalize_output may have already replaced the value with
# the placeholder.
sub expected_to_pattern {
    my ($expected) = @_;

    my $pattern = quotemeta($expected);

    # __ID__ - matches hex IDs like 19b8607cf80ae931b1f (timestamp + random)
    $pattern =~ s/__ID__/(?:[a-f0-9]{15,20}|__ID__)/g;

    # __UUID__ - matches UUIDs like 550e8400-e29b-41d4-a716-446655440000 (case-insensitive)
    $pattern =~ s/__UUID__/(?:[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}|__UUID__)/g;

    # __TIMESTAMP__ - ISO timestamps with or without sub-seconds / timezone.
    $pattern =~ s/__TIMESTAMP__/(?:\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}(?::\\d{2})?(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})?|__TIMESTAMP__)/g;

    # __DATE__ - dates like "Jan 3 23:43" or "2025-01-03" (DirectoryLister).
    $pattern =~ s/__DATE__/(?:\\w{3}\\s+\\d{1,2}\\s+\\d{2}:\\d{2}|\\d{4}-\\d{2}-\\d{2}|__DATE__)/g;

    # __NUMBER__ - any number (integer or decimal)
    $pattern =~ s/__NUMBER__/(?:-?\\d+(?:\\.\\d+)?|__NUMBER__)/g;

    # __STRING__ - any non-empty string (non-greedy, no quotes)
    $pattern =~ s/__STRING__/(?:.+?|__STRING__)/g;

    # __HASH__ - hash values (32-64 hex chars), used by HashTest.
    $pattern =~ s/__HASH__/(?:[a-f0-9]{32,64}|__HASH__)/g;

    # __TOTAL__ - block count from `ls -la`.
    $pattern =~ s/__TOTAL__/(?:\\d+|__TOTAL__)/g;

    # __TIME__ - decimals like generationtime_ms (0.08, 1.23).
    $pattern =~ s/__TIME__/(?:\\d+\\.\\d+|__TIME__)/g;

    return $pattern;
}

# `--generate` writes the captured output as expected.txt, but raw output
# usually contains dynamic values (timestamps, IDs) that would never match on
# a second run. Convert those to placeholders.
sub auto_placeholderize {
    my ($output, $type) = @_;

    if ($type && $type eq 'http') {
        # Hex IDs (15-20 chars) in JSON id fields.
        $output =~ s/"id":"[a-f0-9]{15,20}"/"id":"__ID__"/g;
        # UUIDs (e.g. in observer output after ---server--- separator).
        $output =~ s/[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}/__UUID__/g;
        # Normalize floats with excessive precision (249.99000000000001 -> 249.99).
        $output =~ s/(\d+\.\d{1,2})0{6,}\d+/$1/g;
    }

    # ISO timestamps (with or without seconds, timezone).
    $output =~ s/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?/__TIMESTAMP__/g;

    if ($type && $type eq 'console') {
        # Special-case generationtime_ms from the weather API stub.
        $output =~ s/generationtime_ms:\s*\d+\.\d+/generationtime_ms: __TIME__/g;
        # Weather fields whose numeric values vary by stub run.
        $output =~ s/(temperature|windspeed|winddirection|elevation|latitude|longitude|is_day|weathercode):\s*-?\d+(?:\.\d+)?/$1: __NUMBER__/g;
    }

    return $output;
}

# Strict line-by-line pattern match. Both inputs must have the same number of
# lines; each expected line is converted to a regex via expected_to_pattern.
sub matches_pattern {
    my ($actual, $expected) = @_;

    my @actual_lines = split /\n/, $actual;
    my @expected_lines = split /\n/, $expected;

    return 0 if scalar(@actual_lines) != scalar(@expected_lines);

    for (my $i = 0; $i < scalar(@expected_lines); $i++) {
        my $pattern = expected_to_pattern($expected_lines[$i]);
        unless ($actual_lines[$i] =~ /^$pattern$/) {
            return 0;
        }
    }

    return 1;
}

# Order-independent check: every non-blank expected line must appear somewhere
# in $actual. Returns (passed, \@missing_lines).
sub check_output_occurrences {
    my ($actual, $expected) = @_;

    my @expected_lines = split /\n/, $expected;
    my @missing = ();

    for my $expected_line (@expected_lines) {
        next if $expected_line =~ /^\s*$/;
        my $pattern = expected_to_pattern($expected_line);
        unless ($actual =~ /$pattern/m) {
            push @missing, $expected_line;
        }
    }

    return (scalar(@missing) == 0, \@missing);
}

1;
