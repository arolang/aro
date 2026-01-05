#!/usr/bin/env perl
# Unit tests for AROTest::Config

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

BEGIN {
    use_ok('AROTest::Config');
}

# Test constructor with default options
{
    my $config = AROTest::Config->new();
    isa_ok($config, 'AROTest::Config', 'new() returns Config object');

    # Test default values
    is($config->timeout, 10, 'default timeout is 10 seconds');
    is($config->is_verbose, 0, 'default verbose is false');
    is($config->is_generate, 0, 'default generate is false');
    is($config->filter, '', 'default filter is empty string');
    like($config->examples_dir, qr/Examples$/, 'default examples_dir ends with Examples');
}

# Test constructor with custom options
{
    my $config = AROTest::Config->new(
        timeout => 30,
        verbose => 1,
        generate => 1,
        filter => 'HTTP',
        examples_dir => '/tmp/test',
    );

    is($config->timeout, 30, 'custom timeout is set');
    is($config->is_verbose, 1, 'custom verbose is set');
    is($config->is_generate, 1, 'custom generate is set');
    is($config->filter, 'HTTP', 'custom filter is set');
    is($config->examples_dir, '/tmp/test', 'custom examples_dir is set');
}

# Test singleton behavior
{
    my $config1 = AROTest::Config->new(timeout => 15);
    my $config2 = AROTest::Config->instance();

    is($config2->timeout, 15, 'instance() returns same config');
    is($config1, $config2, 'instance() returns same object reference');
}

# Test cleanup handlers
{
    my $config = AROTest::Config->new();
    my $cleanup_called = 0;

    $config->add_cleanup_handler(sub { $cleanup_called = 1; });

    $config->run_cleanup_handlers();
    is($cleanup_called, 1, 'cleanup handler was executed');
}

# Test multiple cleanup handlers
{
    my $config = AROTest::Config->new();
    my @calls = ();

    $config->add_cleanup_handler(sub { push @calls, 'first'; });
    $config->add_cleanup_handler(sub { push @calls, 'second'; });
    $config->add_cleanup_handler(sub { push @calls, 'third'; });

    $config->run_cleanup_handlers();
    is(scalar @calls, 3, 'all cleanup handlers executed');
    is_deeply(\@calls, ['first', 'second', 'third'], 'handlers executed in order');
}

done_testing();
