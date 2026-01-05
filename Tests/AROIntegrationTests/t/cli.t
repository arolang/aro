#!/usr/bin/env perl
# Unit tests for AROTest::CLI

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

BEGIN {
    use_ok('AROTest::CLI', qw(parse_args));
}

# Test parse_args() with no arguments
{
    my ($options, $filters) = parse_args();

    isa_ok($options, 'HASH', 'parse_args() returns options hash');
    isa_ok($filters, 'ARRAY', 'parse_args() returns filters array');

    is($options->{timeout}, 10, 'default timeout is 10');
    is($options->{verbose}, 0, 'default verbose is false');
    is($options->{generate}, 0, 'default generate is false');
    is($options->{help}, 0, 'default help is false');
    is(scalar @$filters, 0, 'no filters by default');
}

# Test parse_args() with --verbose flag
{
    my ($options, $filters) = parse_args('--verbose');

    is($options->{verbose}, 1, '--verbose sets verbose flag');
}

# Test parse_args() with --generate flag
{
    my ($options, $filters) = parse_args('--generate');

    is($options->{generate}, 1, '--generate sets generate flag');
}

# Test parse_args() with --timeout option
{
    my ($options, $filters) = parse_args('--timeout=30');

    is($options->{timeout}, 30, '--timeout sets custom timeout');
}

# Test parse_args() with --filter option
{
    my ($options, $filters) = parse_args('--filter=HTTP');

    is($options->{filter}, 'HTTP', '--filter sets filter pattern');
}

# Test parse_args() with example filters
{
    my ($options, $filters) = parse_args('HelloWorld', 'Calculator', 'HTTPServer');

    is(scalar @$filters, 3, 'example filters are captured');
    is_deeply($filters, ['HelloWorld', 'Calculator', 'HTTPServer'], 'example filters are correct');
}

# Test parse_args() with mixed arguments
{
    my ($options, $filters) = parse_args('--verbose', '--timeout=20', 'HelloWorld', 'Calculator');

    is($options->{verbose}, 1, 'verbose flag parsed with mixed args');
}

done_testing();
