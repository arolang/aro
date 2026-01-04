package AROTest::Comparison::Matching;

use strict;
use warnings;
use v5.30;
use Exporter 'import';

our @EXPORT_OK = qw(matches_pattern check_occurrences auto_placeholderize);

=head1 NAME

AROTest::Comparison::Matching - Pattern matching for test comparison

=head1 SYNOPSIS

    use AROTest::Comparison::Matching qw(matches_pattern check_occurrences);

    if (matches_pattern($actual, $expected)) {
        print "Output matches!\n";
    }

    my ($success, $missing_lines) = check_occurrences($actual, $expected);

=head1 DESCRIPTION

Provides pattern matching functionality for comparing test outputs.
Supports placeholders for dynamic values like timestamps, UUIDs, and IDs.

=head2 PLACEHOLDERS

The following placeholders are supported in expected output:

=over 4

=item * C<__ID__> - Hex IDs (15-20 chars)

=item * C<__UUID__> - Standard UUIDs

=item * C<__TIMESTAMP__> - ISO timestamps

=item * C<__DATE__> - Date formats

=item * C<__NUMBER__> - Any number

=item * C<__STRING__> - Any string

=item * C<__HASH__> - Hash values (32-64 hex chars)

=item * C<__TOTAL__> - Total blocks count

=item * C<__TIME__> - Decimal time values

=back

=cut

=head2 matches_pattern($actual, $expected)

Check if actual output matches expected pattern with placeholder support.
Performs strict line-by-line comparison with same line count requirement.

Parameters:

=over 4

=item * C<$actual> - The actual output string

=item * C<$expected> - The expected pattern (with placeholders)

=back

Returns: 1 if matches, 0 otherwise

=cut

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
        my $pattern = _expected_to_pattern($expected_line);

        # Check if actual line matches pattern
        unless ($actual_line =~ /^$pattern$/) {
            return 0;
        }
    }

    # All lines matched
    return 1;
}

=head2 check_occurrences($actual, $expected)

Check if all expected lines occur in output (order-independent).
Useful for tests where output order may vary.

Parameters:

=over 4

=item * C<$actual> - The actual output string

=item * C<$expected> - The expected output (each line should appear)

=back

Returns: C<($success, \@missing_lines)>

=cut

sub check_occurrences {
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

=head2 auto_placeholderize($output, $type)

Automatically replace dynamic values with placeholders for --generate mode.

Parameters:

=over 4

=item * C<$output> - The output string to process

=item * C<$type> - Test type hint ('http', 'console', etc.)

=back

Returns: Output with dynamic values replaced by placeholders

=cut

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

# Private: Convert expected output with placeholders to regex pattern
sub _expected_to_pattern {
    my ($expected) = @_;

    # Escape regex metacharacters in the expected string
    my $pattern = quotemeta($expected);

    # Replace escaped placeholders with actual regex patterns
    # __ID__ - matches hex IDs like 19b8607cf80ae931b1f (timestamp + random)
    $pattern =~ s/__ID__/[a-f0-9]{15,20}/g;

    # __UUID__ - matches UUIDs like 550e8400-e29b-41d4-a716-446655440000
    $pattern =~ s/__UUID__/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/g;

    # __TIMESTAMP__ - matches ISO timestamps like 2025-01-03T23:43:37.478982169+01:00 or 2026-01-03T22:45
    $pattern =~ s/__TIMESTAMP__/\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}(?::\\d{2})?(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})?/g;

    # __DATE__ - matches dates like Jan 3 23:43 or 2025-01-03 (already used in DirectoryLister)
    $pattern =~ s/__DATE__/(?:\\w{3}\\s+\\d{1,2}\\s+\\d{2}:\\d{2}|\\d{4}-\\d{2}-\\d{2})/g;

    # __NUMBER__ - matches any number (integer or decimal)
    $pattern =~ s/__NUMBER__/-?\\d+(?:\\.\\d+)?/g;

    # __STRING__ - matches any non-empty string (non-greedy, no quotes)
    $pattern =~ s/__STRING__/.+?/g;

    # __HASH__ - matches hash values (32-64 hex chars) - already used in HashTest
    $pattern =~ s/__HASH__/[a-f0-9]{32,64}/g;

    # __TOTAL__ - matches total blocks count in ls output
    $pattern =~ s/__TOTAL__/\\d+/g;

    # __TIME__ - matches decimal time values like generationtime_ms (0.08, 1.23)
    $pattern =~ s/__TIME__/\\d+\\.\\d+/g;

    return $pattern;
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
