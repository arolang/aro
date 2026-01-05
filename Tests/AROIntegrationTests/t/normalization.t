#!/usr/bin/env perl
# Unit tests for AROTest::Comparison::Normalization

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

BEGIN {
    use_ok('AROTest::Comparison::Normalization', qw(normalize_output normalize_feature_prefix));
}

# Test normalize_feature_prefix()
{
    my $input = "[FeatureSetName] Hello, World!";
    my $output = normalize_feature_prefix($input);
    is($output, "Hello, World!", 'removes feature set prefix');
}

# Test normalize_feature_prefix() with multiple lines
{
    my $input = "[FeatureSet1] Line 1\n[FeatureSet2] Line 2\n[FeatureSet3] Line 3";
    my $output = normalize_feature_prefix($input);
    is($output, "Line 1\nLine 2\nLine 3", 'removes multiple prefixes');
}

# Test normalize_feature_prefix() with no prefix
{
    my $input = "No prefix here";
    my $output = normalize_feature_prefix($input);
    is($output, "No prefix here", 'leaves text without prefix unchanged');
}

# Test normalize_output() for console type
{
    my $input = "Hello, World!";
    my $output = normalize_output($input, 'console');
    ok(defined $output, 'normalize_output() returns defined value for console');
}

# Test normalize_output() for HTTP type
{
    my $input = "HTTP/1.1 200 OK\nContent-Type: application/json\n{\"message\":\"test\"}";
    my $output = normalize_output($input, 'http');
    ok(defined $output, 'normalize_output() returns defined value for HTTP');
}

# Test normalize_output() removes trailing spaces
{
    my $input = "Line 1  \nLine 2   \nLine 3  \n";
    my $output = normalize_output($input, 'console');
    unlike($output, qr/ +$/m, 'removes trailing spaces');
}

# Test normalize_output() with mixed prefixes and whitespace
{
    my $input = "[Feature] Line 1  \n[Another] Line 2  \nPlain line  ";
    my $output = normalize_output($input, 'console');

    # normalize_output removes trailing spaces but not prefixes
    like($output, qr/Line 1/, 'contains line 1 text');
    like($output, qr/Line 2/, 'contains line 2 text');
    like($output, qr/Plain line/, 'contains plain line');
    # normalize_output doesn't remove prefixes - that's normalize_feature_prefix's job
    like($output, qr/\[Feature\]/, 'normalize_output preserves feature prefixes');
}

# Test normalize_feature_prefix() with unusual input
{
    my $input = "[FeatureSet] Content";
    my $output = normalize_feature_prefix($input);
    is($output, "Content", 'removes simple feature prefix');
}

# Test normalize_output() preserves content
{
    my $input = "Important content\nAnother line\nThird line";
    my $output = normalize_output($input, 'console');
    like($output, qr/Important content/, 'preserves first line');
    like($output, qr/Another line/, 'preserves second line');
    like($output, qr/Third line/, 'preserves third line');
}

# Test empty string
{
    my $output1 = normalize_feature_prefix('');
    is($output1, '', 'normalize_feature_prefix handles empty string');

    my $output2 = normalize_output('', 'console');
    is($output2, '', 'normalize_output handles empty string');
}

# Test whitespace-only string
{
    my $output = normalize_output("   \n\t\n   ", 'console');
    ok(defined $output, 'handles whitespace-only string');
}

done_testing();
