package AROTest::Comparison::Normalization;

use strict;
use warnings;
use v5.30;
use FindBin qw($RealBin);
use Exporter 'import';

our @EXPORT_OK = qw(normalize_output normalize_feature_prefix);

=head1 NAME

AROTest::Comparison::Normalization - Output normalization for test comparison

=head1 SYNOPSIS

    use AROTest::Comparison::Normalization qw(normalize_output normalize_feature_prefix);

    my $normalized = normalize_output($output, 'console');
    my $cleaned = normalize_feature_prefix($output);

=head1 DESCRIPTION

Normalizes test output to enable consistent comparison between runs.
Handles timestamps, paths, whitespace, and other dynamic values.

=cut

=head2 normalize_output($output, $type)

Normalize output for comparison. Applies multiple transformations:

=over 4

=item * ISO timestamps -> __TIMESTAMP__

=item * ls -la timestamps -> __DATE__

=item * ls -la total blocks -> __TOTAL__

=item * API response times -> __TIME__

=item * Absolute paths -> Relative paths

=item * Line endings -> Unix format

=item * Trailing whitespace -> Removed

=item * Hash values -> __HASH__ (if type is 'hash')

=back

Parameters:

=over 4

=item * C<$output> - The output string to normalize

=item * C<$type> - Optional type hint (e.g., 'hash')

=back

Returns: Normalized output string

=cut

sub normalize_output {
    my ($output, $type) = @_;

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
    my $base_dir = File::Spec->catdir($RealBin, '..', '..');
    $output =~ s/\Q$base_dir\E/./g;

    # Normalize line endings
    $output =~ s/\r\n/\n/g;

    # Remove trailing whitespace
    $output =~ s/ +$//gm;

    # Normalize hash values (for HashTest example)
    $output =~ s/\b[a-f0-9]{32,64}\b/__HASH__/g if $type && $type eq 'hash';

    return $output;
}

=head2 normalize_feature_prefix($output)

Strip optional feature-set prefix and response formatting from output lines.
The interpreter outputs [Feature-Name] prefix, but binaries don't. Binaries
may also output response formatting lines.

This allows the same expected.txt to match both interpreter and binary outputs.

Transformations:

=over 4

=item * C<[Application-Start] message> -> C<message>

=item * Response formatting lines (C<  value: ...>) -> Removed

=item * Multiple blank lines -> Single blank line

=back

Parameters:

=over 4

=item * C<$output> - The output string to normalize

=back

Returns: Output with prefixes and formatting removed

=cut

sub normalize_feature_prefix {
    my ($output) = @_;

    # Remove [feature-set-name] prefix from each line
    # Matches: [anything-in-brackets] followed by space
    # Example: "[Application-Start] message" -> "message"
    $output =~ s/^\[[^\]]+\]\s+//gm;

    # Remove response formatting lines (start with whitespace + key: value)
    # Example: "  value: Hello" or "  status: 200"
    # These are from Response.format() output that binaries include
    $output =~ s/^\s+\w+:.*$//gm;

    # Remove empty lines created by the above filtering
    $output =~ s/\n\n+/\n/g;

    return $output;
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
