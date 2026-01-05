#!/usr/bin/env perl
# Unit tests for AROTest::Comparison::Matching

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

BEGIN {
    use_ok('AROTest::Comparison::Matching', qw(matches_pattern check_occurrences auto_placeholderize));
}

# Test exact match
{
    my $actual = "Hello, World!";
    my $expected = "Hello, World!";
    ok(matches_pattern($actual, $expected), 'exact match returns true');
}

# Test mismatch
{
    my $actual = "Hello, World!";
    my $expected = "Goodbye, World!";
    ok(!matches_pattern($actual, $expected), 'mismatch returns false');
}

# Test __ID__ placeholder
{
    my $actual = "User ID: abc123def456789";
    my $expected = "User ID: __ID__";
    ok(matches_pattern($actual, $expected), '__ID__ placeholder matches hex ID');
}

# Test __UUID__ placeholder
{
    my $actual = "Request ID: 550e8400-e29b-41d4-a716-446655440000";
    my $expected = "Request ID: __UUID__";
    ok(matches_pattern($actual, $expected), '__UUID__ placeholder matches UUID');
}

# Test __TIMESTAMP__ placeholder
{
    my $actual = "Created at: 2024-01-15T10:30:45Z";
    my $expected = "Created at: __TIMESTAMP__";
    ok(matches_pattern($actual, $expected), '__TIMESTAMP__ placeholder matches ISO timestamp');
}

# Test __NUMBER__ placeholder
{
    my $actual = "Count: 42";
    my $expected = "Count: __NUMBER__";
    ok(matches_pattern($actual, $expected), '__NUMBER__ placeholder matches integer');

    my $actual2 = "Price: 99.99";
    my $expected2 = "Price: __NUMBER__";
    ok(matches_pattern($actual2, $expected2), '__NUMBER__ placeholder matches decimal');
}

# Test __STRING__ placeholder
{
    my $actual = "Name: John Doe";
    my $expected = "Name: __STRING__";
    ok(matches_pattern($actual, $expected), '__STRING__ placeholder matches any string');
}

# Test __HASH__ placeholder
{
    my $actual = "Hash: 5d41402abc4b2a76b9719d911017c592";
    my $expected = "Hash: __HASH__";
    ok(matches_pattern($actual, $expected), '__HASH__ placeholder matches MD5 hash');
}

# Test __TIME__ placeholder
{
    my $actual = "Duration: 1.234s";
    my $expected = "Duration: __TIME__s";
    ok(matches_pattern($actual, $expected), '__TIME__ placeholder matches decimal time');
}

# Test multiple placeholders on separate lines
{
    my $actual = "User: abc123def456789\nID: 550e8400-e29b-41d4-a716-446655440000\nCreated: 2024-01-15T10:30:45Z";
    my $expected = "User: __ID__\nID: __UUID__\nCreated: __TIMESTAMP__";
    ok(matches_pattern($actual, $expected), 'multiple placeholders work on separate lines');
}

# Test multiline matching
{
    my $actual = "Line 1\nLine 2\nLine 3";
    my $expected = "Line 1\nLine 2\nLine 3";
    ok(matches_pattern($actual, $expected), 'multiline exact match');
}

# Test multiline with placeholders (same line count required)
{
    my $actual = "Request ID: abc123def456789012\nTimestamp: 2024-01-15T10:30:45Z\nStatus: OK";
    my $expected = "Request ID: __ID__\nTimestamp: __TIMESTAMP__\nStatus: OK";
    ok(matches_pattern($actual, $expected), 'multiline with placeholders and same line count');
}

# Test check_occurrences() - all lines present
{
    my $actual = "Line 1\nLine 2\nLine 3";
    my $expected = "Line 1\nLine 2\nLine 3";
    my ($success, $missing) = check_occurrences($actual, $expected);
    ok($success, 'check_occurrences returns true when all lines present');
    is(scalar @$missing, 0, 'no missing lines');
}

# Test check_occurrences() - missing line
{
    my $actual = "Line 1\nLine 3";
    my $expected = "Line 1\nLine 2\nLine 3";
    my ($success, $missing) = check_occurrences($actual, $expected);
    ok(!$success, 'check_occurrences returns false when line missing');
    ok(scalar @$missing > 0, 'reports missing lines');
}

# Test check_occurrences() - extra lines in actual
{
    my $actual = "Line 1\nExtra Line\nLine 2\nLine 3";
    my $expected = "Line 1\nLine 2\nLine 3";
    my ($success, $missing) = check_occurrences($actual, $expected);
    ok($success, 'check_occurrences ignores extra lines in actual');
}

# Test auto_placeholderize() - replaces IDs in HTTP JSON
{
    my $input = '{"id":"abc123def456789012","name":"test"}';
    my $output = auto_placeholderize($input, 'http');
    like($output, qr/__ID__/, 'auto_placeholderize replaces hex IDs in JSON for HTTP type');
}

# Test auto_placeholderize() - doesn't replace arbitrary UUIDs
{
    my $input = "Request: 550e8400-e29b-41d4-a716-446655440000";
    my $output = auto_placeholderize($input, 'console');
    # auto_placeholderize doesn't replace UUIDs, only specific patterns
    unlike($output, qr/__UUID__/, 'auto_placeholderize does not replace arbitrary UUIDs');
}

# Test auto_placeholderize() - replaces timestamps
{
    my $input = "Created: 2024-01-15T10:30:45Z";
    my $output = auto_placeholderize($input, 'console');
    like($output, qr/__TIMESTAMP__/, 'auto_placeholderize replaces ISO timestamps');
}

# Test auto_placeholderize() - preserves normal text
{
    my $input = "Hello, World! This is a test.";
    my $output = auto_placeholderize($input, 'console');
    is($output, $input, 'auto_placeholderize preserves normal text');
}

# Test empty strings
{
    ok(matches_pattern('', ''), 'empty strings match');

    my ($success, $missing) = check_occurrences('', '');
    ok($success, 'empty strings check_occurrences');

    my $output = auto_placeholderize('', 'console');
    is($output, '', 'auto_placeholderize handles empty string');
}

# Test case sensitivity
{
    my $actual = "Hello, World!";
    my $expected = "hello, world!";
    ok(!matches_pattern($actual, $expected), 'matching is case-sensitive');
}

done_testing();
